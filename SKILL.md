---
name: codex-plugin-repair-windows
description: Repair Windows Codex Desktop bundled plugin state after app updates, especially Chrome, Computer Use, openai-bundled marketplace, native host, chrome/latest, and user-profile plugin cache issues. Use when Windows 版 Codex 更新后 Chrome 插件或 Computer Use 插件消失、不可用、未 installed/enabled、native host 异常、openai-bundled 缺失、latest 链接损坏，或 Computer Use runtime 无法启动。User-profile repair only; do not MSIX repatch.
---

# Windows Codex 插件修复

## 适用范围

用于修复 Windows 版 Codex Desktop 更新后，用户目录里的 bundled 插件状态异常。重点处理 `~/.codex` 插件缓存、本地 `openai-bundled` marketplace 镜像、Chrome native messaging 注册、`chrome-native-hosts.json`，以及 `config.toml` 里的插件启用状态。

不要调用 MSIX repatch 脚本，不要编辑 `C:\Program Files\WindowsApps`。除非运行时验证明确出现 OS error 740 或 `spawn setup refresh` 失败，否则不要修改 `[windows] sandbox`。

## 工作流

1. 在 PowerShell 中运行内置脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-plugin-repair-windows\scripts\repair-openai-bundled-plugins.ps1"
```

2. 阅读脚本末尾的 JSON summary。
3. 如果 `computerUseHelper` 为 `false`，先看输出里的缺失路径，再判断是否需要额外安装 Computer Use compatibility overlay。
4. 如果 sandbox 启动失败并出现 OS error 740，再备份 `config.toml` 后考虑设置 `[windows] sandbox = "unelevated"`。不要预先盲改。

## 脚本会修复什么

- 备份 `config.toml`、`.codex-global-state.json`、`chrome-native-hosts.json` 和已有本地 marketplace 状态。
- 将当前 Desktop 包内置的 `openai-bundled` marketplace 同步到 `~/.codex\.tmp\bundled-marketplaces\openai-bundled`。
- 确保 `[marketplaces.openai-bundled]` 指向这个本地镜像。
- 将 `chrome@openai-bundled` 安装或刷新到 `~/.codex\plugins\cache\openai-bundled\chrome\<version>`，并更新 `chrome\latest`。
- 如果当前 bundled marketplace 里有 `computer-use`，同步到 `~/.codex\plugins\cache\openai-bundled\computer-use\<version>`，并更新 `computer-use\latest`。
- 运行 Chrome 插件自带的 `installManifest.mjs`，写入 native host manifest 和 HKCU Chrome 注册表项。
- 用当前有效路径更新 `~/.codex\chrome-native-hosts.json`。
- 启用 `[plugins."chrome@openai-bundled"]`，并在可用时启用 `[plugins."computer-use@openai-bundled"]`，同时保留原有配置。
- 验证 Chrome native host manifest、Chrome Extension 安装状态、Computer Use helper 路径和 TOML 语法。

## 验证预期

成功修复后，summary 中通常应看到：

- `marketplaceManifest = true`
- `chromeLatest = true`
- `chromeBrowserClient = true`
- `nativeHostManifestOk = true`
- `chromeExtensionInstalled = true`
- `chromeEnabledInConfig = true`
- `computerUseEnabledInConfig = true` when Computer Use is installed
- `computerUseEnabledInConfig = true`，如果当前环境安装了 Computer Use

修复后提醒用户重启 Codex Desktop 和 Chrome，让两个应用重新加载 native host 和插件状态。
