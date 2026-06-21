param(
  [switch]$DiagnoseOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)
  Write-Host "[codex-plugin-repair] $Message"
}

function Test-Leaf {
  param([string]$Path)
  return [bool](Test-Path -LiteralPath $Path -PathType Leaf)
}

function Test-AnyPath {
  param([string]$Path)
  return [bool](Test-Path -LiteralPath $Path)
}

function Copy-IfExists {
  param(
    [string]$Path,
    [string]$Destination
  )
  if (Test-Path -LiteralPath $Path) {
    Copy-Item -LiteralPath $Path -Destination $Destination -Recurse -Force
    return $true
  }
  return $false
}

function Remove-LinkDirectory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.LinkType -ne 'Junction' -and $item.LinkType -ne 'SymbolicLink') {
    throw "Refusing to remove non-link path: $Path"
  }
  [System.IO.Directory]::Delete($Path, $false)
}

function Invoke-CheckedNative {
  param([scriptblock]$Command)
  $output = & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "native command failed LASTEXITCODE=$LASTEXITCODE"
  }
  return $output
}

function Resolve-CodexResources {
  param([string]$ConfigPath)

  $candidates = [System.Collections.Generic.List[string]]::new()
  $tomlText = if (Test-Leaf $ConfigPath) { Get-Content -LiteralPath $ConfigPath -Raw } else { '' }

  foreach ($pattern in @(
    "CODEX_CLI_PATH\s*=\s*['""]([^'""]*?resources[\\/]+codex\.exe)['""]",
    "command\s*=\s*['""]([^'""]*?resources[\\/]+cua_node[\\/]+bin[\\/]+node_repl\.exe)['""]",
    "NODE_REPL_NODE_PATH\s*=\s*['""]([^'""]*?resources[\\/]+cua_node[\\/]+bin[\\/]+node\.exe)['""]"
  )) {
    $m = [regex]::Match($tomlText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $path = $m.Groups[1].Value
      $resourcesIndex = $path.LastIndexOf('\resources\', [System.StringComparison]::OrdinalIgnoreCase)
      if ($resourcesIndex -ge 0) {
        $candidates.Add($path.Substring(0, $resourcesIndex + '\resources'.Length))
      }
    }
  }

  try {
    foreach ($path in (& where.exe codex.exe 2>$null)) {
      if ($path -match '[\\/]resources[\\/]codex\.exe$') {
        $candidates.Add((Split-Path -Parent $path))
      }
    }
  } catch {
    # where.exe is only an additional hint.
  }

  try {
    $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Select-Object -First 1
    if ($pkg) {
      $candidates.Add((Join-Path $pkg.InstallLocation 'app\resources'))
    }
  } catch {
    Write-Step "AppX package discovery unavailable; trying portable/runtime paths"
  }

  foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    $manifest = Join-Path $candidate 'plugins\openai-bundled\.agents\plugins\marketplace.json'
    if (Test-Leaf $manifest) {
      return [pscustomobject]@{
        ResourcesPath = $candidate
        MarketplacePath = Join-Path $candidate 'plugins\openai-bundled'
      }
    }
  }

  throw 'Codex bundled resources not found. Checked config paths, PATH codex.exe, and AppX package hints.'
}

function Sync-DirectoryIncremental {
  param(
    [string]$Source,
    [string]$Destination
  )
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy $Source $Destination /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
  if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed LASTEXITCODE=$LASTEXITCODE source=$Source destination=$Destination"
  }
}

function Repair-EncodedNodeModulePaths {
  param([string]$NodeModules)

  if (-not (Test-Path -LiteralPath $NodeModules -PathType Container)) {
    return 0
  }

  $created = 0
  Get-ChildItem -LiteralPath $NodeModules -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*%40*' } |
    ForEach-Object {
      $decodedName = $_.Name -replace '%40', '@'
      if ($decodedName -eq $_.Name) {
        return
      }
      $link = Join-Path $_.Parent.FullName $decodedName
      if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
          return
        }
        throw "Refusing to replace existing non-link path: $link"
      }
      New-Item -ItemType Junction -Path $link -Target $_.FullName | Out-Null
      $created += 1
    }

  Get-ChildItem -LiteralPath $NodeModules -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*%24*' } |
    ForEach-Object {
      $decodedName = $_.Name -replace '%24', '$'
      if ($decodedName -eq $_.Name) {
        return
      }
      $link = Join-Path $_.DirectoryName $decodedName
      if (Test-Path -LiteralPath $link) {
        return
      }
      New-Item -ItemType HardLink -Path $link -Target $_.FullName | Out-Null
      $created += 1
    }

  return $created
}

function Update-TomlBlock {
  param(
    [string]$ConfigPath,
    [string]$Header,
    [hashtable]$Values
  )

  $text = ''
  if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $text = Get-Content -LiteralPath $ConfigPath -Raw
  }

  $escaped = [regex]::Escape($Header)
  $blockPattern = "(?ms)^$escaped\s*\r?\n.*?(?=^\[|\z)"
  $lines = @($Header)
  foreach ($key in ($Values.Keys | Sort-Object)) {
    $value = $Values[$key]
    if ($value -is [bool]) {
      $rendered = if ($value) { 'true' } else { 'false' }
    } else {
      $rendered = "'" + (($value.ToString()) -replace "'", "''") + "'"
    }
    $lines += "$key = $rendered"
  }
  $block = ($lines -join [Environment]::NewLine) + [Environment]::NewLine

  if ($text -match $blockPattern) {
    $text = [regex]::Replace($text, $blockPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
  } else {
    if ($text.Length -gt 0 -and -not $text.EndsWith([Environment]::NewLine)) {
      $text += [Environment]::NewLine
    }
    $text += [Environment]::NewLine + $block
  }

  Set-Content -LiteralPath $ConfigPath -Value $text -Encoding UTF8
}

function Get-TomlSummary {
  param([string]$ConfigPath)
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) {
    return $null
  }

  $code = @'
import json, pathlib, sys, tomllib
p = pathlib.Path(sys.argv[1])
cfg = tomllib.loads(p.read_text(encoding="utf-8-sig"))
print(json.dumps({
  "browserEnabledInConfig": cfg.get("plugins", {}).get("browser@openai-bundled", {}).get("enabled"),
  "chromeEnabledInConfig": cfg.get("plugins", {}).get("chrome@openai-bundled", {}).get("enabled"),
  "computerUseEnabledInConfig": cfg.get("plugins", {}).get("computer-use@openai-bundled", {}).get("enabled"),
  "featuresComputerUse": cfg.get("features", {}).get("computer_use"),
  "windowsSandbox": cfg.get("windows", {}).get("sandbox"),
  "openaiBundledMarketplace": cfg.get("marketplaces", {}).get("openai-bundled", {}),
}, ensure_ascii=False))
'@
  $tmp = Join-Path $env:TEMP ('codex-toml-summary-' + [guid]::NewGuid().ToString() + '.py')
  try {
    Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8
    $raw = & $python.Source $tmp $ConfigPath
    return ($raw | ConvertFrom-Json)
  } finally {
    if (Test-Path -LiteralPath $tmp) {
      Remove-Item -LiteralPath $tmp -Force
    }
  }
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $codexHome "backups\plugin-repair-$timestamp"
$configPath = Join-Path $codexHome 'config.toml'
$globalStatePath = Join-Path $codexHome '.codex-global-state.json'
$chromeHostsStatePath = Join-Path $codexHome 'chrome-native-hosts.json'
$marketplaceMirror = Join-Path $codexHome '.tmp\bundled-marketplaces\openai-bundled'
$pluginCacheRoot = Join-Path $codexHome 'plugins\cache\openai-bundled'

$codexResources = Resolve-CodexResources $configPath
$packageMarketplace = $codexResources.MarketplacePath
$resourcesPath = $codexResources.ResourcesPath
$packageManifest = Join-Path $packageMarketplace '.agents\plugins\marketplace.json'
if (-not (Test-Leaf $packageManifest)) {
  throw "Bundled marketplace manifest not found in current Codex resources: $packageManifest"
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-IfExists $configPath (Join-Path $backupDir 'config.toml') | Out-Null
Copy-IfExists $globalStatePath (Join-Path $backupDir '.codex-global-state.json') | Out-Null
Copy-IfExists $chromeHostsStatePath (Join-Path $backupDir 'chrome-native-hosts.json') | Out-Null
Copy-IfExists $marketplaceMirror (Join-Path $backupDir 'openai-bundled-marketplace') | Out-Null
Write-Step "backup: $backupDir"

if (-not $DiagnoseOnly) {
  Write-Step "syncing bundled marketplace mirror from current Codex resources"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marketplaceMirror) | Out-Null
  Sync-DirectoryIncremental $packageMarketplace $marketplaceMirror
}

$chromeSource = Join-Path $packageMarketplace 'plugins\chrome'
$chromePluginJson = Join-Path $chromeSource '.codex-plugin\plugin.json'
if (-not (Test-Leaf $chromePluginJson)) {
  throw "Chrome plugin metadata not found: $chromePluginJson"
}
$chromeMeta = Get-Content -LiteralPath $chromePluginJson -Raw | ConvertFrom-Json
$chromeVersion = $chromeMeta.version
$chromeCacheRoot = Join-Path $pluginCacheRoot 'chrome'
$chromeVersionDir = Join-Path $chromeCacheRoot $chromeVersion
$chromeLatest = Join-Path $chromeCacheRoot 'latest'

if (-not $DiagnoseOnly) {
  Write-Step "refreshing chrome cache version $chromeVersion"
  New-Item -ItemType Directory -Force -Path $chromeCacheRoot | Out-Null
  Sync-DirectoryIncremental $chromeSource $chromeVersionDir

    if (Test-Path -LiteralPath $chromeLatest) {
      $latestItem = Get-Item -LiteralPath $chromeLatest -Force
      if ($latestItem.LinkType -eq 'Junction' -or $latestItem.LinkType -eq 'SymbolicLink') {
        Remove-LinkDirectory $chromeLatest
      } else {
        throw "Refusing to replace non-link chrome latest path: $chromeLatest"
      }
  }
  New-Item -ItemType Junction -Path $chromeLatest -Target $chromeVersionDir | Out-Null
}

$browserSource = Join-Path $packageMarketplace 'plugins\browser'
$browserVersion = $null
$browserCacheRoot = Join-Path $pluginCacheRoot 'browser'
$browserLatest = Join-Path $browserCacheRoot 'latest'
$browserVersionDir = $null
if (Test-AnyPath $browserSource) {
  $browserPluginJson = Join-Path $browserSource '.codex-plugin\plugin.json'
  if (Test-Leaf $browserPluginJson) {
    $browserMeta = Get-Content -LiteralPath $browserPluginJson -Raw | ConvertFrom-Json
    $browserVersion = $browserMeta.version
    $browserVersionDir = Join-Path $browserCacheRoot $browserVersion

    if (-not $DiagnoseOnly) {
      Write-Step "refreshing browser cache version $browserVersion"
      New-Item -ItemType Directory -Force -Path $browserCacheRoot | Out-Null
      Sync-DirectoryIncremental $browserSource $browserVersionDir

      if (Test-Path -LiteralPath $browserLatest) {
        $browserLatestItem = Get-Item -LiteralPath $browserLatest -Force
        if ($browserLatestItem.LinkType -eq 'Junction' -or $browserLatestItem.LinkType -eq 'SymbolicLink') {
          Remove-LinkDirectory $browserLatest
        } else {
          throw "Refusing to replace non-link browser latest path: $browserLatest"
        }
      }
      New-Item -ItemType Junction -Path $browserLatest -Target $browserVersionDir | Out-Null
    }
  }
}

$computerUseSource = Join-Path $packageMarketplace 'plugins\computer-use'
$computerUseVersion = $null
$computerUseCacheRoot = Join-Path $pluginCacheRoot 'computer-use'
$computerUseLatest = Join-Path $computerUseCacheRoot 'latest'
$computerUseVersionDir = $null
if (Test-AnyPath $computerUseSource) {
  $computerUsePluginJson = Join-Path $computerUseSource '.codex-plugin\plugin.json'
  if (Test-Leaf $computerUsePluginJson) {
    $computerUseMeta = Get-Content -LiteralPath $computerUsePluginJson -Raw | ConvertFrom-Json
    $computerUseVersion = $computerUseMeta.version
    $computerUseVersionDir = Join-Path $computerUseCacheRoot $computerUseVersion

    if (-not $DiagnoseOnly) {
      Write-Step "refreshing computer-use cache version $computerUseVersion"
      New-Item -ItemType Directory -Force -Path $computerUseCacheRoot | Out-Null
      Sync-DirectoryIncremental $computerUseSource $computerUseVersionDir

      if (Test-Path -LiteralPath $computerUseLatest) {
        $cuLatestItem = Get-Item -LiteralPath $computerUseLatest -Force
        if ($cuLatestItem.LinkType -eq 'Junction' -or $cuLatestItem.LinkType -eq 'SymbolicLink') {
          Remove-LinkDirectory $computerUseLatest
        } else {
          throw "Refusing to replace non-link computer-use latest path: $computerUseLatest"
        }
      }
      New-Item -ItemType Junction -Path $computerUseLatest -Target $computerUseVersionDir | Out-Null
    }
  }
}

$browserClientPath = Join-Path $chromeLatest 'scripts\browser-client.mjs'
$extensionHostPath = Join-Path $chromeLatest 'extension-host\windows\x64\extension-host.exe'
$installManifestPath = Join-Path $chromeLatest 'scripts\installManifest.mjs'
$nodePath = $null
$nodeReplPath = $null
$codexCliPath = $null

$tomlText = if (Test-Leaf $configPath) { Get-Content -LiteralPath $configPath -Raw } else { '' }
foreach ($pair in @(
  @{ Name = 'nodePath'; Pattern = "NODE_REPL_NODE_PATH\s*=\s*['""]([^'""]+)['""]" },
  @{ Name = 'nodeReplPath'; Pattern = "command\s*=\s*['""]([^'""]*node_repl\.exe)['""]" },
  @{ Name = 'codexCliPath'; Pattern = "CODEX_CLI_PATH\s*=\s*['""]([^'""]+)['""]" }
)) {
  $m = [regex]::Match($tomlText, $pair.Pattern)
  if ($m.Success) {
    Set-Variable -Name $pair.Name -Value $m.Groups[1].Value
  }
}

if (-not $nodePath) {
  $nodePath = (Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Recurse -Filter node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (-not $nodeReplPath) {
  $nodeReplPath = (Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Recurse -Filter node_repl.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (-not $codexCliPath) {
  $codexCliPath = Join-Path $resourcesPath 'codex.exe'
}

if (-not (Test-Leaf $nodePath)) { throw "node.exe not found: $nodePath" }
if (-not (Test-Leaf $nodeReplPath)) { throw "node_repl.exe not found: $nodeReplPath" }
if (-not (Test-Leaf $codexCliPath)) { throw "codex.exe not found: $codexCliPath" }

$nodeModulesPath = Split-Path -Parent $nodePath
$nodeModulesPath = Join-Path $nodeModulesPath 'node_modules'
$encodedNodeModuleFixes = 0
$cuaNodeSetupOk = $null
if (-not $DiagnoseOnly) {
  Write-Step "repairing encoded Node module paths"
  $encodedNodeModuleFixes = Repair-EncodedNodeModulePaths $nodeModulesPath
  $setupScript = Join-Path $resourcesPath 'cua_node\bin\setup.ps1'
  if (Test-Leaf $setupScript) {
    Write-Step "validating cua_node runtime"
    try {
      powershell -NoProfile -ExecutionPolicy Bypass -File $setupScript | Write-Host
      $cuaNodeSetupOk = ($LASTEXITCODE -eq 0)
      if (-not $cuaNodeSetupOk) {
        throw "cua_node setup failed LASTEXITCODE=$LASTEXITCODE"
      }
    } catch {
      $cuaNodeSetupOk = $false
      throw
    }
  }
}

if (-not $DiagnoseOnly) {
  Write-Step "updating config.toml plugin and marketplace entries"
  $configBackupDir = Join-Path $codexHome 'backups\config'
  New-Item -ItemType Directory -Force -Path $configBackupDir | Out-Null
  if (Test-Leaf $configPath) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $configBackupDir "config.toml.$timestamp.codex-plugin-repair.bak") -Force
  }

  Update-TomlBlock $configPath '[marketplaces.openai-bundled]' @{
    source_type = 'local'
    source = "\\?\$packageMarketplace"
    last_updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  if ($browserVersion) {
    Update-TomlBlock $configPath '[plugins."browser@openai-bundled"]' @{ enabled = $true }
  }
  Update-TomlBlock $configPath '[plugins."chrome@openai-bundled"]' @{ enabled = $true }
  if ($computerUseVersion) {
    Update-TomlBlock $configPath '[plugins."computer-use@openai-bundled"]' @{ enabled = $true }
  }

  $computerUseRuntimeExe = Join-Path $nodeModulesPath '@oai\sky\bin\windows\codex-computer-use.exe'
  if (Test-Leaf $computerUseRuntimeExe) {
    $text = Get-Content -LiteralPath $configPath -Raw
    $notifyPattern = '(?m)^notify\s*=\s*\[.*?codex-computer-use\.exe"\s*,\s*"turn-ended"\s*\]'
    $notifyReplacement = 'notify = [ "' + $computerUseRuntimeExe.Replace('\', '\\') + '", "turn-ended" ]'
    if ($text -match $notifyPattern) {
      $text = [regex]::Replace($text, $notifyPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $notifyReplacement }, 1)
    } elseif ($text -notmatch '(?m)^notify\s*=') {
      $text = $notifyReplacement + [Environment]::NewLine + $text
    }
    Set-Content -LiteralPath $configPath -Value $text -Encoding UTF8
  }
}

if (-not $DiagnoseOnly) {
  Write-Step "installing Chrome native messaging manifest"
  $installUrl = 'file:///' + $installManifestPath.Replace('\', '/')
  $runtime = [ordered]@{
    codexCliPath = $codexCliPath
    nodePath = $nodePath
    nodeReplPath = $nodeReplPath
  } | ConvertTo-Json -Compress
  $js = @"
const mod = await import($(ConvertTo-Json $installUrl));
await mod.install({ appServerRuntimePaths: $runtime });
console.log('INSTALL_MANIFEST_OK');
"@
  $tmpJs = Join-Path $env:TEMP ('codex-install-chrome-manifest-' + [guid]::NewGuid().ToString() + '.mjs')
  try {
    Set-Content -LiteralPath $tmpJs -Value $js -Encoding UTF8
    & $nodePath $tmpJs | Write-Host
  } finally {
    if (Test-Path -LiteralPath $tmpJs) {
      Remove-Item -LiteralPath $tmpJs -Force
    }
  }

  Write-Step "updating chrome-native-hosts.json"
  $entry = [ordered]@{
    schemaVersion = 1
    browserClientPath = $browserClientPath
    codexCliPath = $codexCliPath
    codexHome = $codexHome
    extensionHostPath = $extensionHostPath
    extensionIds = @('hehggadaopoacecdllhhajmbjkdcmajg')
    nativeHostName = 'com.openai.codexextension'
    nodePath = $nodePath
    nodeReplPath = $nodeReplPath
    pluginVersion = $chromeVersion
    proxyHost = '127.0.0.1'
    proxyPort = 0
    resourcesPath = $resourcesPath
    updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  }
  ([ordered]@{ schemaVersion = 1; chromeNativeHosts = @($entry) } | ConvertTo-Json -Depth 8) |
    Set-Content -LiteralPath $chromeHostsStatePath -Encoding UTF8
}

$nativeHostManifest = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
$nativeHostManifestOk = $false
$chromeExtensionInstalled = $false

$checkNativeScript = Join-Path $chromeLatest 'scripts\check-native-host-manifest.js'
if (Test-Leaf $checkNativeScript) {
  & $nodePath $checkNativeScript | Write-Host
  $nativeHostManifestOk = ($LASTEXITCODE -eq 0)
}

$checkExtensionScript = Join-Path $chromeLatest 'scripts\check-extension-installed.js'
if (Test-Leaf $checkExtensionScript) {
  & $nodePath $checkExtensionScript | Write-Host
  $chromeExtensionInstalled = ($LASTEXITCODE -eq 0)
}

$computerUseLatestExists = Test-AnyPath $computerUseLatest
$computerUseLatestTargetExists = $false
if ($computerUseLatestExists) {
  try {
    $null = Get-ChildItem -LiteralPath $computerUseLatest -Force -ErrorAction Stop | Select-Object -First 1
    $computerUseLatestTargetExists = $true
  } catch {
    $computerUseLatestTargetExists = $false
  }
}
$computerUseHelper = $null
foreach ($root in @($computerUseLatest, $computerUseVersionDir)) {
  if ($root -and (Test-AnyPath $root)) {
    try {
      $match = Get-ChildItem -LiteralPath $root -Recurse -Filter helper_transport.js -ErrorAction Stop | Select-Object -First 1
      if ($match) {
        $computerUseHelper = $match.FullName
        break
      }
    } catch {
      continue
    }
  }
}
$computerUseHelperOk = [bool]$computerUseHelper
$computerUseClient = Test-Leaf (Join-Path $computerUseLatest 'scripts\computer-use-client.mjs')
$computerUseRuntimeExeOk = Test-Leaf (Join-Path $nodeModulesPath '@oai\sky\bin\windows\codex-computer-use.exe')

$tomlSummary = Get-TomlSummary $configPath

$summary = [ordered]@{
  diagnoseOnly = [bool]$DiagnoseOnly
  backupDir = $backupDir
  resourcesPath = $resourcesPath
  bundledMarketplace = $packageMarketplace
  marketplaceManifest = Test-Leaf (Join-Path $packageMarketplace '.agents\plugins\marketplace.json')
  marketplaceMirrorManifest = Test-Leaf (Join-Path $marketplaceMirror '.agents\plugins\marketplace.json')
  browserLatest = Test-AnyPath $browserLatest
  browserClient = Test-Leaf (Join-Path $browserLatest 'scripts\browser-client.mjs')
  chromeLatest = Test-AnyPath $chromeLatest
  chromeBrowserClient = Test-Leaf $browserClientPath
  chromeExtensionHost = Test-Leaf $extensionHostPath
  nativeHostManifest = Test-Leaf $nativeHostManifest
  nativeHostManifestOk = $nativeHostManifestOk
  chromeExtensionInstalled = $chromeExtensionInstalled
  computerUseLatest = $computerUseLatestExists
  computerUseLatestTargetExists = $computerUseLatestTargetExists
  computerUseHelper = $computerUseHelperOk
  computerUseHelperPath = $computerUseHelper
  computerUseClient = $computerUseClient
  computerUseRuntimeExe = $computerUseRuntimeExeOk
  encodedNodeModuleFixes = $encodedNodeModuleFixes
  cuaNodeSetupOk = $cuaNodeSetupOk
  toml = $tomlSummary
}

Write-Host '---SUMMARY---'
$summary | ConvertTo-Json -Depth 8
