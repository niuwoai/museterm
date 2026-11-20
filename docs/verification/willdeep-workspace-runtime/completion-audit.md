# 原方案阶段验收核对

核对日期：2026-10-25。当前源码 1.251.0-rc28 / Build 343；WillDeep 隔离检出 0.115.0-rc1。原方案阶段 0–5 的实现与约定验收已取得证据；这是未提交、未发布、未安装的源码交付，不声称 Herdr 全产品能力或未覆盖场景已经完成。

## 原始范围与证据

| 原方案要求 | 已取得的证据 | 当前判断 |
|---|---|---|
| 阶段 0：源码基线、契约、隔离与阶段依赖 | ../../WILLDEEP_WORKSPACE_RUNTIME_PLAN.md 的基线、边界、状态映射、实施顺序及跨仓库路径 | 方案已有；后续实施没有取消原边界 |
| 阶段 1：WillDeep 原生状态和真实 CLI 接入 | willdeep-native-unit.json、native-tui.json、native-headless-complete.json、native-headless-blocked.json；native-forced-ui.md、release-native-continuity-rc28.json | 原生语义、安全文件、可选接入、任务归属、心跳/过期/替换/迟到与真实 CLI/Runtime/GUI 路径分别验证 |
| 阶段 2：项目、标签、分屏稳定身份和快照迁移 | TerminalProjectLayoutTests/TerminalProjectToolTests/TerminalRuntimeWorkspaceTests；same-directory-project-unit.json、project-layout-gui.json、project-cli-gui.json | 同名同目录项目、移动/重排/关闭、旧/损坏快照、独立焦点及提醒归属验证；稳定身份在真实 PTY 操作中保持 |
| 阶段 3：真实界面创建、输入、拖动、关闭取消、保存恢复 | project-layout-gui.md、project-cli-gui.md；sidebar-layout-en.json、sidebar-layout-zh.json；floating-paste-native.md、attention-navigation-gui.md | 两项目混合分屏真实输入、比例、关闭取消/确认、恢复、跨项目待处理定位、中英文窄侧栏、悬浮/收回分别通过；不是所有组合的穷举 |
| 阶段 4：独立 PTY、退出界面继续、重新附着、输入/resize、限额与恶意客户端 | context-service.json、runtime-capacity.md、runtime-view-control.md、runtime-input-safety.md；release-authenticated-ssh-rc28.json | 真实 PTY/GUI、21 项服务边界、64 会话容量及认证断连通过；原重启用例纠正 shell 就绪假设后 120/120，写前拒绝保持 |
| 阶段 5：发现原会话、回放、原审批、版本兼容、退出/保存语义 | native-orphan-recovery.md、render-checkpoint-crash-ui.md、native-forced-ui.md、old-backend-compatibility.md、compatibility-and-authenticated-ssh.md；attention-navigation-full-unit.json、release-universal-build.json | 正常退出与强制结束后同身份、孤立发现、历史副作用抑制、原审批唯一完成、旧后台不被替换、损坏端点拒绝和保存失败保留查看器通过；Release App 未启动 |

以上历史文件记录其当时版本。当前产品代码完整回归为 621 项，随后新加的同名同目录项目用例单独 1 项通过；两份结果分开记录，不称为同一结果包 622/622。rc28 新增界面行为有当前实际 GUI 证据；历史 GUI 仍只证明其记录的行为及版本。

## 当前最终候选

- attention-navigation-full-unit.json：621/621，通过，0 失败、0 跳过；same-directory-project-unit.json：后补 1/1。
- release-universal-build.json：未签名 Universal Release App/helper 构建通过，QA 专用入口排除；Release App 没有启动或安装。
- release-native-continuity-rc28.json：同一最终 Release helper，实际 WillDeep/私有 Runtime/本机 mock 模型；全部查看端离线 31 秒，原审批保持，批准后原任务完成，当前 CLI 与原生端点双等待通过。
- release-authenticated-ssh-rc28.json：同一 helper 的真实回环 OpenSSH 10 项检查通过，临时密钥已清理；helper SHA 与构建/原生报告相同。
- authenticated-profile.md：实际 Profile/SwiftTerm/PTY 定向 3/3，覆盖手动/自动重连、重试上限和错误主机密钥不自动重试。离屏 AppKit 测试不等于完整 App 菜单验收或外部机器验收。

## 失败处理与范围边界

1. 原重启输入失败已定位为 shell 初始化期间 echo 变化导致正确拒绝；成功路径等待真实提示符，拒绝路径明确验证不重发和显式恢复，120/120 通过。详见 restart-audit.md；尚不能把 transport connected 当作任意 CLI 语义就绪。
2. 本轮还实际发现待处理导航后弹层不收起；rc28 修复，当前真实点击后直接粘贴仅到目标叶子，原问题仅已读且保持唯一。原失败与修复路径见 attention-navigation-gui.md。
3. 原方案阶段 3 要求的中英文、窄窗口、悬浮及恢复分别有证据；没有承诺所有语言/窗口/布局的笛卡尔积。系统通知权限实际投递和外部机器属于额外覆盖，不能由单测/回环 SSH 推导为通过；它们不是本方案三块实现的既定验收门槛。
4. 真实 WillDeep 模型调用使用本机 mock 模型，CLI、Runtime、PTY、状态、审批与界面路径是真实的；不声称外部模型服务兼容性。Release 只完成未签名双架构构建、检查及 helper 跨进程验证，未做签名公证发布或正常安装替换。

## 交付边界

本轮没有提交、打标签、发布、安装、替换本机应用或重启正常 WillDeep Runtime。普通后台默认启用已经进入源码，旧 LocalProcess 会话仍不能无缝迁移；服务崩溃/系统重启不承诺原进程恢复。ask user、confirm、model selector 外化继续暂缓。

## 已核对的具体单测

当前 Swift 结果包 attention-navigation-full-unit.json 覆盖：

- TerminalNativeAgentTests：testBootstrapIsPrivateAndOnlyBindsStatusForItsOwnTerminal、testTrackingDisabledRejectsNativeBinding、testDistinctGatesAndTasksDoNotCollapseIntoOldAttention。
- TerminalAgentStateTests：testOldBindingCannotOverwriteReplacement、testOutOfOrderAndDuplicateReportsLeaveStateUnchanged、testExpirationBecomesUnknownAndFreshReportRecovers、testExitRevokesCapabilityAndDoesNotInventSuccessfulResult、testHeartbeatDoesNotFloodSemanticEventsOrLeakCapability。
- TerminalProjectLayoutTests：testSplitMoveAndClosePreserveTerminalIdentityAndCollapseTree、testSnapshotRoundTripAndCorruptDuplicateLeafRejection、testLegacySnapshotRestoresTabsAndSelectedTerminalWithoutInventingSplits。
- TerminalRuntimeWorkspaceTests：testOrdinaryApplicationEnablesPersistentRuntimeByDefault、testTestHostsKeepPersistentRuntimeExplicitlyOptedIn、testPrivateStoreRejectsSymlinkAndRetainsVictim、testCorruptRecordIsRetainedAndNotUsedAsNewShellConfiguration、testDifferentWindowsClaimDifferentRecordsWithoutDuplicatingTerminals、testRecoveryRecordOmitsEnvironmentStartupCommandsAndSSHOptions。

本轮在 /private/tmp/qterm-willdeep-native 执行 `cargo test -p willdeep qterm:: -- --test-threads=1`，16/16 通过。已检查测试正文，包含缺失端点可选接入、私有文件/符号链接拒绝、递增序号、任务和会话归属、审批阶段身份、语义状态映射及关闭前发送最终结果。不把该单元结果当作真实 GUI 或远端服务证明。

补充的失败边界：TerminalRuntimeCompatibilityTests 的 incompatible/malformed/wrong identity/oversized/service epoch 五项拒绝不替换原进程；TerminalRuntimeViewTests 的 testMissingPersistedRuntimeDoesNotCreateReplacementShell、testSaveFailureKeepsOriginalViewerConnected、testWorkspaceExitPersistsIdentityAndRestoresSameRealPTYWithoutStartupInput、testExistingRuntimeDiscoveredBeforeGenerationWasSavedDoesNotReplayStartup 证明缺失会话不伪造、保存失败保留、退出恢复和不重发启动命令。musetermApp.applicationShouldTerminate 捕获保存错误并返回 terminateCancel，普通应用后台默认启用及测试宿主隔离开关有明确单测。状态专用绑定与输入租约分离；关闭跟踪不会授予输入权限，相关设置/状态测试在同一完整回归中。

WillDeep Reporter.from_env 在 QTERM_AGENT_CONTEXT 缺失或无效时立即返回默认无 worker 状态；缺失端点、私有文件与符号链接测试见 willdeep-native-unit.json。主任务/子任务、会话切换、过期 Runtime、最终结果发送分别有命名用例和真实 CLI 验证。版本在 Cargo 工作区与 web/package.json 均为 0.115.0-rc1。

## 可审查源码交付

QTerm 源码在当前功能分支，所有修改保持未提交。WillDeep 源码在 /private/tmp/qterm-willdeep-native，另保存 willdeep-native-source.patch（含四个新增源文件）及 willdeep-native-source.json，记录基线 208b124cb0452358b079652dbcd6eb1922184c6b。补丁在一次性干净基线索引中 git apply --cached --check 通过，没有修改正常检出或真实索引。
