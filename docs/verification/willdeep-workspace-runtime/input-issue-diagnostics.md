# 后台重启输入与提示保留验证

工作区：1.251.0-rc22 / Build 337。正式后台入口仍关闭，未替换本机应用。

## 已确认的问题与改动

rc21 完整串行回归中，已退出 PTY 重启后偶发没有执行输入。原样重复仍可复现。增加独立 ACK 检查后，失败发生在后台输入序号前进之前，因此不能将它归因于后台已接收后 shell 丢弃输入。原始失败报告保留，不增加超时或自动重发输入。

另一个确定的问题是 `TerminalHostController.startRuntime` 的输出回调无条件清除连接提示，可能掩盖输入拒绝或输入过大。当前改动保留这两类提示，直到成功输入或用户明确关闭提示；输入失败另外保存经既有 `diagnosticCode` 脱敏的错误码，不保存命令、凭据或原始错误正文。

新增真实 PTY 回归先拒绝超大输入，再从独立后台路径触发实际输出，确认提示仍在；随后从控制器正常输入，等待真实命令结果并确认提示清除。

## 结果与局限

| 结果包 | 范围 | 结果 |
|---|---|---|
| `/private/tmp/qterm-restart-diagnose-01.xcresult` | rc21 原用例单次 | 通过，不能据此关闭间歇性问题 |
| `/private/tmp/qterm-restart-diagnose-repeat-01.xcresult` | 原样重复 12 次 | 11 通过、1 失败 |
| `/private/tmp/qterm-restart-ack-diagnose-01.xcresult` | ACK 阶段诊断重复 12 次 | 11 通过、1 失败；失败时输入序号为 1 |
| `/private/tmp/qterm-restart-error-diagnose-01.xcresult` | 带安全错误码的重启回归 12 次 | 12 通过 |
| `/private/tmp/qterm-restart-error-repeat-02.xcresult` | 重启和提示保留各 40 次 | 80 通过、0 失败、0 跳过 |
| `/private/tmp/qterm-input-issue-full-01.xcresult` | 当前完整串行回归 | 610/610，0 失败、0 跳过；见 input-issue-full-unit.json |

重启问题的具体拒绝原因尚未捕获；后两轮通过不代表已查明根因。安全 echo/前台进程/输入代次检查保持原样，不通过自动重试掩盖失败。全部测试使用自有私有后台和真实 PTY，不访问正常终端会话。
