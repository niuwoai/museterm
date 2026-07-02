# MuseTerm

MuseTerm 是一个轻快的 macOS 多标签终端应用，使用 SwiftUI 构建外壳界面，并通过 SwiftTerm 提供本地 shell 终端能力。

![MuseTerm screenshot](snip.png)

## 核心能力

- 多标签终端，支持快捷键新建、切换和关闭标签。
- SSH 主机管理，支持多跳、独立密钥和连接后启动命令。
- 终端录制捷径，可录制输入并在当前标签回放。
- rz/sz 文件传输，支持上传、下载、远端依赖检查和进度展示。
- 主题、字体、光标、ANSI 配色和毛玻璃设置。
- CLI/MCP 工具桥，可让本机工具读取终端屏幕、历史并发送输入。

## 运行

1. 打开 `museterm.xcodeproj`
2. 选择 `museterm` scheme
3. 在 Xcode 中运行

## 常见操作

如果关闭运行中标签时勾选过“以后不再询问”，本机偏好会保留这个选择。要恢复关闭确认弹窗，可以运行：

```bash
defaults delete im.some.museterm terminal.skipRunningTabCloseConfirmation
```

## 版本

当前版本：`v1.209.0`
