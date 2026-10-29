# Codex /pet 用量伴随层 macOS 版

这是 Windows 版 `CodexPetUsageOverlay.ps1` 的 macOS 适配实现。它不修改 Codex，只读取本机 Codex 状态文件定位 `/pet`，并用本机 Codex 登录态查询用量。

当前推荐使用仓库中的 Hammerspoon 2.0 实现：鼠标移到宠物上立即显示圆环，连续悬停 3 秒切换为详情卡片，移开后隐藏。它针对内置于 `ChatGPT.app` 的 Codex 26.x 状态格式重新适配，并支持 Retina 与多屏坐标换算。

本目录中的 Swift/AppKit 实现作为旧版兼容代码保留，不应与 Hammerspoon 版同时运行，否则会出现重复圆环。

## 运行

在仓库根目录下执行：

```zsh
cd macos
./Start.command
./Status.command
./Stop.command
```

或直接双击：

```text
macos/Start.command
macos/Stop.command
macos/Status.command
macos/InstallStartup.command
macos/UninstallStartup.command
```

首次运行会自动用 `swiftc` 编译到：

```text
macos/.build/codex-pet-usage-overlay-mac
```

## 可调参数

```zsh
./Start.command --usage-poll-seconds 30 --pet-poll-ms 100 --hover-padding-px 24
```

## 开机自启

```zsh
./InstallStartup.command
```

它会写入当前用户的 LaunchAgent：

```text
~/Library/LaunchAgents/dev.jimmyasksai.codex-pet-usage-overlay.plist
```

并把运行二进制安装到稳定位置：

```text
~/Library/Application Support/CodexPetUsageOverlay/codex-pet-usage-overlay-mac
```

取消自启：

```zsh
./UninstallStartup.command
```

## 数据与隐私

本工具读取：

```text
~/.codex/.codex-global-state.json
~/.codex/auth.json
~/.codex/logs_2.sqlite 或 logs_1.sqlite
```

实时用量只把本地 Codex access token 用于：

```text
https://chatgpt.com/backend-api/wham/usage
```

不会发送宠物图片、截图、prompt、仓库内容或日志正文到其他位置。

## 运行状态

```text
~/Library/Application Support/CodexPetUsageOverlay/overlay.pid
~/Library/Application Support/CodexPetUsageOverlay/overlay.log
```

## 故障排查

- 没看到悬浮层：确认 Codex Desktop 里已经打开 `/pet`，然后把鼠标移动到宠物身上。
- 菜单栏或 Dock 没有图标是正常的；它是一个后台透明悬浮窗。
- 显示用量不可用：运行 `Status.command`，再看 `overlay.log`。
- 多屏位置不对：先确认 Codex 的 `/pet` 在当前屏幕可见，再重启 `Start.command`。
