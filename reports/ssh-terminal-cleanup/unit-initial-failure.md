# 本轮完整回归的早期失败记录

- 版本：1.261.0-rc3 / Build 384。
- 原始结果：765 通过、1 失败、0 跳过，耗时 186.445 秒。
- 本地原始证据（未提交到仓库）：`.derivedData/ssh-terminal-cleanup/20261120T052740.xcresult` 及 `.derivedData/ssh-terminal-cleanup/20261120T052740.log`。
- 失败用例：`TerminalRuntimeViewTests/testSaveFailureKeepsOriginalViewerConnected()`。

失败输出：

```text
Runtime view timed out at original still accepts input after save failure:
connected=true,metadata=true,error=nil,inputError=input_echo_changed,inputSequence=1,characters=44
```

该用例原先仅等待 Runtime 已连接，随即向刚启动的交互式 `/bin/sh -i` 输入命令，未等待其终端回显状态就绪。输入预检与写入之间回显变化会被现有安全校验拒绝，导致本次超时。

此次只调整测试夹具：复用同文件已有 `echoControlledShell`，等待 `__MODE_READY` 后继续原有保存失败与输入断言。产品输入校验没有放松，未添加自动重试输入，也没有更改该用例所验证的保存失败行为。

第二轮完整回归中，保存失败用例已通过，`testFirstAttachSynchronizesActualPTYSizeAfterEarlyLayout()` 出现同类超时：

```text
Runtime view timed out at stty confirms real PTY dimensions:
connected=true,metadata=true,error=nil,inputError=input_echo_changed,inputSequence=1,characters=44
```

第二轮结果同为 765 通过、1 失败、0 跳过，耗时 187.594 秒，原始 `.xcresult` 为 `.derivedData/ssh-terminal-cleanup/20261120T053321.xcresult`，本地完整日志为 `.derivedData/ssh-terminal-cleanup/20261120T053321.log`（未提交到仓库）。此尺寸用例也改用相同固定回显夹具，在尺寸已同步且 `__MODE_READY` 出现后才发送 `stty size`，保留真实 PTY 尺寸断言。

最终完整回归结果以 [unit.md](unit.md) 和 [unit.json](unit.json) 为准。
