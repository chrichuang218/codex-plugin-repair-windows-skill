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

$pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
if (-not $pkg) {
  throw 'OpenAI.Codex AppX package not found.'
}

$packageMarketplace = Join-Path $pkg.InstallLocation 'app\resources\plugins\openai-bundled'
$packageManifest = Join-Path $packageMarketplace '.agents\plugins\marketplace.json'
if (-not (Test-Leaf $packageManifest)) {
  throw "Bundled marketplace manifest not found in current Codex package: $packageManifest"
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-IfExists $configPath (Join-Path $backupDir 'config.toml') | Out-Null
Copy-IfExists $globalStatePath (Join-Path $backupDir '.codex-global-state.json') | Out-Null
Copy-IfExists $chromeHostsStatePath (Join-Path $backupDir 'chrome-native-hosts.json') | Out-Null
Copy-IfExists $marketplaceMirror (Join-Path $backupDir 'openai-bundled-marketplace') | Out-Null
Write-Step "backup: $backupDir"

if (-not $DiagnoseOnly) {
  Write-Step "syncing bundled marketplace from current Codex package"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marketplaceMirror) | Out-Null
  if (Test-Path -LiteralPath $marketplaceMirror) {
    Remove-Item -LiteralPath $marketplaceMirror -Recurse -Force
  }
  Copy-Item -LiteralPath $packageMarketplace -Destination $marketplaceMirror -Recurse -Force
}

$chromeSource = Join-Path $marketplaceMirror 'plugins\chrome'
if (-not (Test-AnyPath $chromeSource)) {
  $chromeSource = Join-Path $packageMarketplace 'plugins\chrome'
}
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
  if (-not (Test-Path -LiteralPath $chromeVersionDir)) {
    Copy-Item -LiteralPath $chromeSource -Destination $chromeVersionDir -Recurse -Force
  } else {
    Copy-Item -LiteralPath (Join-Path $chromeSource '*') -Destination $chromeVersionDir -Recurse -Force
  }

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

$browserSource = Join-Path $marketplaceMirror 'plugins\browser'
if (-not (Test-AnyPath $browserSource)) {
  $browserSource = Join-Path $packageMarketplace 'plugins\browser'
}
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
      if (-not (Test-Path -LiteralPath $browserVersionDir)) {
        Copy-Item -LiteralPath $browserSource -Destination $browserVersionDir -Recurse -Force
      } else {
        Copy-Item -LiteralPath (Join-Path $browserSource '*') -Destination $browserVersionDir -Recurse -Force
      }

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

$computerUseSource = Join-Path $marketplaceMirror 'plugins\computer-use'
if (-not (Test-AnyPath $computerUseSource)) {
  $computerUseSource = Join-Path $packageMarketplace 'plugins\computer-use'
}
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
      if (-not (Test-Path -LiteralPath $computerUseVersionDir)) {
        Copy-Item -LiteralPath $computerUseSource -Destination $computerUseVersionDir -Recurse -Force
      } else {
        Copy-Item -LiteralPath (Join-Path $computerUseSource '*') -Destination $computerUseVersionDir -Recurse -Force
      }

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
  $codexCliPath = (Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Recurse -Filter codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}

if (-not (Test-Leaf $nodePath)) { throw "node.exe not found: $nodePath" }
if (-not (Test-Leaf $nodeReplPath)) { throw "node_repl.exe not found: $nodeReplPath" }
if (-not (Test-Leaf $codexCliPath)) { throw "codex.exe not found: $codexCliPath" }

if (-not $DiagnoseOnly) {
  Write-Step "updating config.toml plugin and marketplace entries"
  $configBackupDir = Join-Path $codexHome 'backups\config'
  New-Item -ItemType Directory -Force -Path $configBackupDir | Out-Null
  if (Test-Leaf $configPath) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $configBackupDir "config.toml.$timestamp.codex-plugin-repair.bak") -Force
  }

  Update-TomlBlock $configPath '[marketplaces.openai-bundled]' @{
    source_type = 'local'
    source = "\\?\$marketplaceMirror"
    last_updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  if ($browserVersion) {
    Update-TomlBlock $configPath '[plugins."browser@openai-bundled"]' @{ enabled = $true }
  }
  Update-TomlBlock $configPath '[plugins."chrome@openai-bundled"]' @{ enabled = $true }
  if ($computerUseVersion) {
    Update-TomlBlock $configPath '[plugins."computer-use@openai-bundled"]' @{ enabled = $true }
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
    resourcesPath = (Join-Path $pkg.InstallLocation 'app\resources')
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

$tomlSummary = Get-TomlSummary $configPath

$summary = [ordered]@{
  diagnoseOnly = [bool]$DiagnoseOnly
  backupDir = $backupDir
  codexPackageVersion = $pkg.Version.ToString()
  codexPackageSignature = $pkg.SignatureKind.ToString()
  marketplaceManifest = Test-Leaf (Join-Path $marketplaceMirror '.agents\plugins\marketplace.json')
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
  toml = $tomlSummary
}

Write-Host '---SUMMARY---'
$summary | ConvertTo-Json -Depth 8
