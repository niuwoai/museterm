# 冷启动恢复验证 — 1.256.0-rc7 / 365

日期：2026-11-02。

## 根因与恢复边界

后台持有 PTY；工作区文件保存布局、终端 UUID、generation 和输出游标，不保存运行进程。后台退出后，旧实现仍强制附着记录中的 generation，既没有进程可接回，也无法重新打开本地 shell。首次创建请求发出前就标记必须恢复，以及并发启动时的文件发布/锁竞争误判，会产生相同的不可用状态。

本次修复只有在认证成功且完整的会话列表确认原 UUID 缺失后，才为已知普通本地 shell 在原目录创建新进程。保留逻辑终端与布局，清除旧输出游标，明确提示原任务没有恢复；不重放 Profile 启动命令。仍存活的会话严格校验 generation；SSH、自定义程序、已删除 Profile 与未知配置不自动重建。失败窗格保持可见，避免连带隐藏分屏里的正常终端。

创建请求发送前，通过主线程同步持久化 `runtimePendingCreationEpoch` 和原恢复身份。该可选字段与旧快照兼容，不改变 Runtime 协议 3。创建确认尚未应用便退出时，下一次可从同一个服务 epoch 认回替代进程；不允许用另一个 epoch 的待创建记录放宽 generation 校验。保存失败阻止创建，明确的拒绝响应清除待创建状态并恢复重试资格，传输失败则保留结果未知的保护。

缺失的 SSH 会话显示已结束及新建本地终端入口，不显示无法执行的原 SSH 进程重连按钮。正常退出的、仍由后台保留身份的 SSH 会话继续沿用原重连逻辑。

## 自动回归

最终定向 XCTest：**120 项，0 失败，0 跳过**，不是全项目测试。

覆盖 `TerminalRuntimeColdStartTests`、`TerminalRuntimeServiceTests`、`TerminalRuntimeViewTests`、`TerminalRuntimeCompatibilityTests`、`TerminalRuntimeWorkspaceTests`、`AICommandAssistantTests` 和 `TerminalAIControlTests`。

新增真实私有 PTY 场景包括：

- 后台重启后保留目录/布局，更新 generation，实际命令输入输出正常，不重放 startupCommands。
- 热恢复保留原 PID/generation；错误 generation 和不同服务的待创建身份被拒绝。
- 创建前连接失败、明确创建被拒绝后可以重试。
- 创建意图先落盘，创建回复未应用到会话模型便退出后仍能接回唯一替代进程。
- 保存创建意图失败时不创建进程。
- 缺失的 attach-only / SSH 会话不自动启动进程、不提供无效 SSH 重连。
- 并发发布身份文件、辅助进程锁竞争退出、真正损坏/不兼容端点保持区分。

结果包：`/private/tmp/museterm-rc7-recovery-edges.xcresult`。编译存在既有 Swift 隔离/测试 SDK 警告，运行时有 QoS 优先级警告；未导致测试失败。

## 原生窗口验证与限制

使用 `scripts/verify_runtime_cold_start.rb` 创建唯一 bundle ID、私有 Runtime/工具目录的 Debug QA 应用副本，正常退出/重开确认原 PID 和 generation 保持，再两次停止自有后台模拟冷启动，通过真实 UI 工具桥输入命令、等待实际返回行并截图。测试仅清理自己创建的进程和目录。

第一轮未激活窗口的截图为空白，不能作为视觉通过证据；将 QA 窗口激活后，已实际看到命令、返回行与光标。最后一次构建与原生验证于 12:54 完成，报告与截图为 `reports/runtime-cold-start-1.256.0-rc7-final.*`。人工已核对截图：命令、`__COLD_GUI_VERIFIED_1` 返回行和光标完整可见；恢复提示在终端上方独立占行。自动报告保留额外人工核对要求，不能自动宣称视觉通过。

XCUITest runner 未能开启 automation mode，报 `Timed out while enabling automation mode`，未执行到产品断言；本次不将其计为通过。新增的 UI 冷启动测试保留，实际 GUI 证据来自上述原生应用验证。

以上 GUI 验证是 Debug QA 副本。正式 universal Release 的签名、公证、发布和本地安装结果由发布引擎报告及交付记录单独确认，不能用 Debug 结果替代。测试与安装均不得结束用户正式的持久 Runtime。
