# codex-plugin-repair-windows-skill

用于修复 Windows 版 Codex Desktop 更新后，`Browser`、`Chrome`、`Computer Use` 插件或 `openai-bundled` 本地插件状态异常的问题。

这个仓库是一个 Codex Skill，核心目标是：**只修复用户目录里的插件状态，不做 MSIX repatch，不修改 `C:\Program Files\WindowsApps`**。

## 适用场景

- Windows 版 Codex 更新后，`browser@openai-bundled` 或 `chrome@openai-bundled` 消失或不可用。
- `computer-use@openai-bundled` 显示未安装、未启用，或 runtime 无法启动。
- `~/.codex/plugins/cache/openai-bundled/chrome/latest` 缺失或指向损坏目录。
- `~/.codex/plugins/cache/openai-bundled/browser/latest` 缺失或指向损坏目录。
- `scripts/browser-client.mjs`、`extension-host.exe` 等 Chrome 插件关键文件缺失。
- `[marketplaces.openai-bundled]` 指向残缺的 `.codex\.tmp` marketplace 镜像，导致插件页或会话内工具发现不完整。
- Chrome native host manifest 或 HKCU 注册表项异常。
- `chrome-native-hosts.json` 仍指向旧版 Codex 包或不存在的插件路径。
- Computer Use 的 `latest` junction 悬空，或 `scripts\computer-use-client.mjs` 缺失。
- 便携版 / 自定义安装目录下，`cua_node\bin\node_modules` 中 `%40oai`、`%40statsig`、`%40npmcli`、`%24...` 等 URL 编码路径导致 `@oai/sky`、npm 或 Computer Use runtime 无法解析。
- `config.toml` 中 `notify = [...codex-computer-use.exe, "turn-ended"]` 指向旧版本缓存路径。

## 不做什么

- 不重打包 Codex Desktop MSIX。
- 不修改 `C:\Program Files\WindowsApps`。
- 不主动修改 `[windows] sandbox`。
- 不绕过 Windows、Chrome 或 Codex 的安全限制。
- 不手动启动 `codex-computer-use.exe`，Computer Use 仍应通过 Codex Desktop 插件和用户确认链路启动。

只有当运行时明确出现 OS error 740 / `spawn setup refresh` 这类错误时，才应在备份后考虑 `[windows] sandbox = "unelevated"`。

## 安装

把仓库复制或克隆到 Codex skills 目录，例如：

```powershell
git clone https://github.com/chrichuang218/codex-plugin-repair-windows-skill.git "$env:USERPROFILE\.codex\skills\codex-plugin-repair-windows-skill"
```

如果你已经安装在旧目录名下，也可以直接使用，只要 `SKILL.md` 存在即可。

## 使用

直接运行修复脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-plugin-repair-windows-skill\scripts\repair-openai-bundled-plugins.ps1"
```

只诊断、不写入修复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-plugin-repair-windows-skill\scripts\repair-openai-bundled-plugins.ps1" -DiagnoseOnly
```

如果你的目录仍是旧名：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-plugin-repair-windows\scripts\repair-openai-bundled-plugins.ps1"
```

## 修复内容

脚本会自动：

- 备份 `config.toml`、`.codex-global-state.json`、`chrome-native-hosts.json` 和本地 marketplace 状态。
- 自动发现当前 Codex Desktop resources 路径，支持 AppX 安装和 `D:\...\versions\current\resources` 这类便携版 / 自定义安装。
- 从当前 Codex Desktop 包增量同步 `openai-bundled` marketplace 到 `~/.codex\.tmp\bundled-marketplaces\openai-bundled`，作为备份镜像。
- 修复 `[marketplaces.openai-bundled]` 指向当前 Desktop 的稳定 bundled 源目录 `resources\plugins\openai-bundled`，避免 `.tmp` 镜像被覆盖残缺后插件不可发现。
- 安装或刷新 `chrome@openai-bundled` cache，并重建 `chrome\latest`。
- 安装或刷新 `browser@openai-bundled` cache，并重建 `browser\latest`。
- 安装或刷新 `computer-use@openai-bundled` cache，并重建 `computer-use\latest`。
- 修复 `cua_node\bin\node_modules` 中 URL 编码路径导致的 Node 模块解析失败：
  - `%40...` 目录补充对应 `@...` junction。
  - `%24...` 文件补充对应 `$...` hardlink。
- 运行当前 Desktop 自带的 `cua_node\bin\setup.ps1`，验证 `@oai/sky`、`codex-computer-use.exe`、`helper_transport.js`、npm 和 `node_repl.exe`。
- 修复 `config.toml` 中失效的 `notify` 旧版 `codex-computer-use.exe` 路径。
- 运行 Chrome 插件自带的 `installManifest.mjs`，写入 native host manifest 和 HKCU 注册表项。
- 更新 `chrome-native-hosts.json` 到当前有效路径。
- 启用 `browser@openai-bundled`、`chrome@openai-bundled` 和可用时的 `computer-use@openai-bundled`。
- 验证 Chrome native host、Chrome Extension、Computer Use client/runtime、`cua_node` runtime 和 TOML 配置。

## 验证结果

成功时，脚本末尾的 JSON summary 通常应包含：

```json
{
  "marketplaceManifest": true,
  "browserLatest": true,
  "browserClient": true,
  "chromeLatest": true,
  "chromeBrowserClient": true,
  "chromeExtensionHost": true,
  "nativeHostManifest": true,
  "nativeHostManifestOk": true,
  "chromeExtensionInstalled": true,
  "computerUseLatest": true,
  "computerUseLatestTargetExists": true,
  "computerUseClient": true,
  "computerUseRuntimeExe": true,
  "cuaNodeSetupOk": true
}
```

说明：

- 新版 Computer Use 主要通过 `scripts\computer-use-client.mjs` 和 bundled `@oai\sky` runtime 工作，`computerUseHelper=false` 不一定代表失败。
- 便携版环境中，`marketplaceMirrorManifest=false` 也不一定代表失败；只要 `marketplaceManifest=true`，且 `toml.openaiBundledMarketplace.source` 指向当前 Desktop `resources\plugins\openai-bundled`，就是预期状态。

修复后建议重启 Codex Desktop 和 Chrome，让它们重新加载插件与 native host 状态。

## 中文 skill 校验

Windows 中文环境下，Python 可能默认用 GBK 读取 `SKILL.md`，导致中文校验报错。校验时建议启用 UTF-8：

```powershell
$env:PYTHONUTF8='1'
python "$env:USERPROFILE\.codex\skills\.system\skill-creator\scripts\quick_validate.py" "$env:USERPROFILE\.codex\skills\codex-plugin-repair-windows-skill"
```

## 关键词

Codex, Codex Desktop, Windows Codex, Codex Skill, Chrome Plugin, Computer Use, openai-bundled, native host, chrome latest, plugin repair, Windows plugin cache.

## 🙏 致谢

感谢 [LINUX DO](https://linux.do/) 社区的支持与讨论。

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
