# WillDeep 审批期间强制结束界面并恢复

日期：2026-10-24。QTerm 1.251.0-rc15 / Build 330；隔离 WillDeep CLI 0.115.0-rc1。

结果：通过。真实隔离 QTerm 图形界面、真实 WillDeep CLI/私有 Runtime、本机 mock 模型；不是通过伪造状态报告替代原生接入。

## 实际步骤与证据

1. 从当前隔离测试构建复制并签名 QA App，在唯一 zsh 终端中通过原生输入启动 WillDeep。发送测试请求，实际严格审批要求批准 `printf qterm_native_probe`。
2. 界面显示 WillDeep 等待处理、项目 1 项等待回答及待处理 1。记录同一后台服务代次、PTY PID/代次、WillDeep 前台 PID、实例/运行/会话/task/gate 和唯一审批 ID；确认该终端已有持久化解析检查点。
3. 核对 PID 完整可执行路径后，仅向本轮 QA App 发送 SIGKILL。确认 UI PID 消失，原后台及原审批保持；离线 42.534 秒后再次核验身份不变。
4. 通过原生界面重开同一 QA App，UI PID 和 UI epoch 改变；后台服务、原 PTY 和 WillDeep 前台 PID、实例/运行/会话/task/gate 均保持。界面和后台都只有原审批事项，实际 TUI 仍显示同一审批对话框。
5. 原生按键 Y 仅允许这条测试命令一次。任务成功完成，原审批消失，后台和 UI 都生成同 task 的唯一完成事项。实际待处理列表显示“已完成，等待查看”。
6. 点击完成事项后，界面数字 0、列表空；读取后台和 UI 快照确认双方都清零。原生输入 `/exit` 退出测试 CLI，显示已退出，驱动成功结束。
7. 正常退出本轮 QA App，确认它的 PID 不在；仅关闭本轮唯一 PTY，空后台正常退出。没有清理其他 QA 或正式会话。

原生输入、审批前/恢复后 TUI、完成事项与已读清零通过 CUA 实际观察。截图在本轮工具输出中显示，未持久化 PNG，不提供不存在的截图链接。

## 报告

- [真实 WillDeep 驱动报告](native-forced-ui.json)：passed=true、2 次本机模型请求、审批时只有 approval，fixtureErrors 为空；WillDeep 二进制与嵌入 helper SHA 固定。
- [强制结束与身份核验](native-forced-ui-identity.json)：before、afterKill、offline、restored、completion 的实际身份与事项；UI PID/epoch、离线时长、已保存游标和清理结果。helper SHA 与上面驱动相同。
- 驱动为 `scripts/verify_willdeep_native.rb` 的 qa-ui 模式。私有 QA 元数据为 `/private/tmp/qterm-native-qa-47bb9afec4f9/qa.json`，补充身份探针为 `/private/tmp/qterm_native_crash_probe.rb`；原驱动报告前缀 `/private/tmp/qterm-native-forced-ui-rc15-01`。

## 范围限制

本用例验证的是单项目/单终端的 WillDeep 审批跨 UI 强制结束连续性；它不证明后台服务自身崩溃或系统重启后任意进程恢复，也不承诺尚未持久化输出窗口零丢失。未覆盖多窗口、全布局、新建项目工具完整 GUI、远端 SSH、旧后台兼容或系统通知投递。

本轮没有修改产品源码，沿用此前 601/601 完整回归构建，没有重复声称重新运行全量。正常后台入口仍关闭，未提交、未发版、未替换本机应用及正常 WillDeep Runtime。本机 QTerm 复核仍为 1.250.0-rc1 / Build 314。
