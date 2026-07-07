# Codex /pet 用量伴随层

这是一个从零写的极简 Windows 伴随层，用来给 Codex Desktop 的 `/pet` 显示实时 Codex 剩余用量。

它不会修改 Codex，也不会复制参考项目代码。它只读取本机 Codex 状态文件来定位宠物，并使用本机 Codex 登录态查询用量。

## 功能

- 鼠标移到 Codex `/pet` 身上时显示透明悬浮层，并保持 10 秒；停在宠物上不会续期，需要移出再移入才会重新触发。默认每 100ms 检测一次鼠标位置，并给宠物区域保留 24px 容错。
- 外圈显示 5 小时窗口剩余用量。
- 内圈显示 7 天窗口剩余用量。
- 中文显示剩余百分比和刷新倒计时。
- 实时接口失败时尝试读取本地 `logs_2.sqlite` / `logs_1.sqlite` 中的 `codex.rate_limits` 事件。
- 不做安装器、开机自启、托盘、设置页、游戏化。

## 运行

双击：

```text
Start.bat
Stop.bat
Status.bat
```

或用 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\CodexPetUsageOverlay.ps1 Start
powershell -ExecutionPolicy Bypass -File .\CodexPetUsageOverlay.ps1 Stop
powershell -ExecutionPolicy Bypass -File .\CodexPetUsageOverlay.ps1 Status
powershell -ExecutionPolicy Bypass -File .\CodexPetUsageOverlay.ps1 SelfTest
```

可调参数：

```powershell
powershell -ExecutionPolicy Bypass -File .\CodexPetUsageOverlay.ps1 Start -PetPollMs 100 -HoverPaddingPx 24
```

## 数据与隐私

本工具读取：

- `%USERPROFILE%\.codex\.codex-global-state.json`
- `%USERPROFILE%\.codex\auth.json`
- `%USERPROFILE%\.codex\logs_2.sqlite` 或 `logs_1.sqlite`

实时用量只把本地 Codex access token 用于：

```text
https://chatgpt.com/backend-api/wham/usage
```

不会发送宠物图片、截图、prompt、仓库内容或日志正文到其他位置。

## 运行状态

运行时文件：

```text
%LOCALAPPDATA%\CodexPetUsageOverlay\overlay.pid
%LOCALAPPDATA%\CodexPetUsageOverlay\overlay.log
```

## 故障排查

- 没看到悬浮层：确认 Codex Desktop 里已经打开 `/pet`，然后把鼠标移到宠物身上。
- 显示用量不可用：先运行 `Status.bat`，再看 `%LOCALAPPDATA%\CodexPetUsageOverlay\overlay.log`。
- 重复启动：`Start` 会复用已运行实例，不会启动多个。
- 要停掉：运行 `Stop.bat`。

## 已知边界

- `wham/usage` 不是公开稳定 API，未来可能变化。
- 本地日志兜底依赖 Codex 日志里出现 `codex.rate_limits` 事件；如果没有事件，会显示不可用。
- v1 不注册开机自启；需要长期使用时再加 Startup shortcut。
