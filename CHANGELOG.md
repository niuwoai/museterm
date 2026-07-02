# Changelog

## [1.187.0] - 2026-07-02

### Added
- SSH 诊断 Markdown 报告新增敏感内容检测状态，复制报告时会明确标明是否检测到疑似敏感内容，以及检测到时是否已经脱敏。
- SSH 生效配置预览窗口会根据已解析的检查结果给出下一步建议，区分 DNS、TCP、配置展开、verbose OpenSSH 失败、需关注、未知、继续检查和全部通过等状态。

## [1.186.0] - 2026-07-02

### Added
- SSH 生效配置预览窗口新增检查结果承接能力，可从剪贴板解析 DNS、TCP、`ssh -G` 和 `ssh -vvv` 输出，在命令行内展示通过、失败、需关注或未知状态、证据行与汇总，并可复制 Markdown 检查结果报告。

## [1.185.0] - 2026-07-02

### Added
- SSH 生效配置预览窗口新增本机检查命令区，可一键写入当前生成配置并复制 DNS、TCP、`ssh -G` 和 `ssh -vvv` 检查命令，减少排查跳板链路时手动拼 `-F` 与 alias 的步骤。
- SSH 诊断 Markdown 报告默认复用 Runbook 敏感信息脱敏规则，复制前会遮蔽常见 token、password、Authorization Bearer、私钥块和 URL 凭据，并在报告头部标明脱敏状态。

## [1.183.0] - 2026-07-02

### Added
- SSH 主机菜单新增“预览生效配置”窗口，可查看 MuseTerm 为当前 Profile 生成并传给 OpenSSH 的配置文本、目标 alias、Host 块数量和行数，并可一键复制完整配置。
- SSH 诊断计划的结果复制升级为 Markdown 报告，包含 Profile、链路、生成时间、汇总、每项检查的状态、证据和原始命令，方便粘贴到 Runbook 或问题记录。

## [1.182.0] - 2026-07-02

### Added
- SSH 诊断计划窗口新增“从剪贴板解析输出”入口，每个步骤可读取用户复制的诊断命令输出，并展示通过、失败、需关注或未知状态、摘要和证据行；窗口会汇总已解析结果，并支持复制或清空诊断结果。

## [1.181.0] - 2026-07-02

### Added
- SSH 主机列表新增端口转发徽标和摘要复制入口，可直接看到 Profile 配置了多少条 Local/Remote/Dynamic 转发，并复制可读的监听与目标端点清单。
- SSH 诊断计划新增结果解析模型，可根据 DNS、TCP、生成配置和 verbose OpenSSH 检查的退出码与输出，归类为通过、失败、需关注或未知，并保留关键证据行。

### Fixed
- SSH 路由诊断的 verbose 成功结果会优先展示 `Exit status 0` 作为证据，避免被较早出现的认证日志行抢占。

## [1.180.0] - 2026-07-02

### Added
- SSH 主机列表新增健康徽标，会把连接前预检问题和高风险 SSH 选项前置展示，并在 hover 摘要里列出需要处理的配置问题或安全提醒。

## [1.179.0] - 2026-07-02

### Added
- SSH 自动重连提示会展示断线原因：网络中断重试、远端主动关闭停止、认证或 Host Key 安全停止等场景会给出不同说明，减少“为什么它又重连/为什么它停了”的猜测。
- SSH 主机菜单新增“诊断计划”窗口，可按链路展示 DNS、TCP、生成配置和逐跳 verbose 检查命令，并支持复制全部命令或逐条填入本地终端；填入时不会自动回车执行。

## [1.178.0] - 2026-07-02

### Added
- SSH 失败链路探测升级为结构化诊断计划，按 DNS 解析、第一跳 TCP 端口、生成配置展开和逐跳 `ssh -vvv` 检查拆分步骤，为后续一键逐跳诊断面板打基础。
- SSH 自动重连新增断线原因分类：区分干净退出、认证或安全停止、远端主动关闭、网络中断和未知失败；远端主动关闭不再被当作网络抖动自动重连。

## [1.177.0] - 2026-07-02

### Added
- SSH 失败诊断新增可粘贴的链路探测建议，会给出本机第一跳端口检查、生成配置展开检查，以及非 Host Key 风险场景下的 `ssh -vvv` 详细链路检查命令。

## [1.176.0] - 2026-07-02

### Added
- SSH 连接前预检新增私钥权限检查：目标机和跳转机密钥文件若对 group/others 开放权限，会提示 `chmod 600` 修复命令，避免 OpenSSH 忽略过宽权限的私钥。

## [1.175.0] - 2026-07-02

### Added
- SSH 失败诊断新增链路定位摘要：当 OpenSSH 报出无法连接或无法解析的主机时，会结合 Profile 跳转链路指出失败更像发生在目标机、第几跳跳板机或未知位置，并展示完整路径与证据行。

## [1.174.0] - 2026-07-02

### Added
- SSH 侧栏新增 `~/.ssh/config` 导入入口，可导入明确 Host 的主机名、用户、端口、密钥、ProxyJump、端口转发、保活和连接复用配置，并跳过通配符 Host。
- SSH 主机菜单新增复制 OpenSSH config 片段，便于把 MuseTerm Profile 带回原生 SSH 配置，同时不会自动改写用户的 `~/.ssh/config`。
- SSH 主机列表新增搜索、分组展示和标签筛选；Profile 编辑器新增分组与标签字段，可按名称、主机、用户、环境、分组、标签与跳转机信息过滤 Profile。

## [1.171.1-rc1] - 2026-07-02

### Fixed
- 将高危命令确认前的输入缓冲与命令候选解析抽为可测试契约，补充退格、Ctrl-C、换行、未提交输入和缓冲截断覆盖，降低安全提示漏判回归风险。

## [1.171.0] - 2026-07-02

### Added
- SSH 标签断线后新增手动重新连接入口：自动重试达到上限或安全原因停止后，可在原标签内一键重连并保留终端历史。

## [1.170.1-rc3] - 2026-07-02

### Fixed
- 修正 v1.170.1-rc2 中误带的 v1.171.0 版本元数据，并把已落地的 SSH 链路与安全提示记录放回 v1.168.0。

## [1.170.1-rc2] - 2026-07-02

### Fixed
- 加固 `Cmd+W` 关闭标签确认期间的重入保护，避免确认弹窗嵌套事件循环里再次收到关闭请求时，先关闭当前标签再用旧索引误关下一个标签。

## [1.170.1-rc1] - 2026-07-02

### Fixed
- 修复 `Cmd+W` 关闭标签时本地快捷键、菜单命令和窗口关闭代理重复处理同一次按键的问题，避免运行中标签确认弹窗连弹两次，以及勾选“以后不再询问”后一次关闭两个标签。

## [1.170.0] - 2026-07-02

### Added
- SSH Host Key 诊断新增保守修复向导：检测到主机指纹校验失败时，终端提示会要求先核对服务器新指纹，并在确认可信后展示对应 `ssh-keygen -R` 清理旧 known_hosts 记录的命令。

## [1.169.0] - 2026-07-02

### Added
- SSH profile 新增连接前静态体检：编辑器会提示重复的端口转发监听地址，以及目标主机或跳转机密钥文件路径不可用等问题，帮助用户在发起连接前修正配置。

## [1.168.0] - 2026-07-01

### Added
- SSH profile 新增链路摘要和安全风险提示：编辑器和侧栏 tooltip 会展示“本机 -> 跳转机 -> 目标机”的连接路径，并对 `ForwardAgent yes`、关闭 Host Key 校验、known_hosts 写入 `/dev/null` 等高风险高级选项给出可见提醒。

## [1.167.0] - 2026-07-01

### Added
- 通知提醒新增可测试的 payload 契约，系统通知标题、正文、单标签冷却 key 与命令隐私开关由纯逻辑统一生成，并补充单测覆盖命令内容隐藏、脱敏展示和事件冷却标识。

## [1.166.0] - 2026-07-01

### Added
- SSH profile 新增保守自动重连设置，支持配置重试次数和基础延迟；SSH 进程异常退出时会在终端提示倒计时并有限重连，认证失败、Host Key 校验失败和认证身份过多等安全敏感错误不会自动重试。

## [1.165.0] - 2026-07-01

### Added
- CLI/MCP 命令查询响应新增 `commandQueryFilters`，用结构化数组回显 `risk`、`lifecycle`、`boundary` 与全文词过滤器，方便外部工具解释查询结果来源。
- 设置新增通知页，支持终端响铃、明显命令失败和长任务完成提醒；App 前台时非当前标签只显示小圆点，App 不活跃时才发送系统通知，并提供失败耗时阈值、长任务阈值、单标签冷却时间和脱敏命令内容开关，降低通知疲劳。

### Fixed
- 通知权限状态判断移除 macOS 不适用的 ephemeral 分支，避免不同 SDK 下授权状态枚举不可用导致构建风险。

## [1.164.1-rc1] - 2026-07-01

### Fixed
- 修复终端主窗口收到关闭请求时仍继续关闭窗口的问题：`Cmd+W` 或窗口关闭命令现在只关闭当前标签，确认运行中进程后也会保留其它标签和 App 窗口；真正退出 App 时仍允许系统关闭窗口。

## [1.164.0] - 2026-07-01

### Added
- CLI `museterm commands --query` 与 MCP `read_commands.query` 新增结构化命令块过滤，支持 `risk:`、`lifecycle:` / `state:`、`boundary:` 和普通全文词组合，并在 payload 顶层返回 `filteredCommandCount` 与 `commandQuery`。

## [1.163.0] - 2026-07-01

### Added
- SSH profile 新增连接复用设置，默认生成 `ControlMaster auto`、`ControlPersist 10m` 与独立 `ControlPath`，让同一主机的新标签页复用既有 SSH master 连接并更快打开。
- SSH profile 新增结构化端口转发配置，支持生成 `LocalForward`、`RemoteForward` 和 `DynamicForward`，并在存在转发时默认启用 `ExitOnForwardFailure yes`，避免端口转发失败被静默吞掉。
- SSH 会话新增常见连接失败诊断提示，可识别认证失败、Host Key 校验失败、连接超时、连接被拒绝、认证身份过多和端口转发失败，并在终端中给出下一步排查建议。
- 新增 `docs/SSH_EXPERIENCE_PLAN.md`，沉淀 SSH 保活、复用、端口转发、跳板可视化、安全护栏、配置导入和失败诊断的后续体验计划。

## [1.162.0] - 2026-07-01

### Added
- SSH profile 新增显式保活设置，默认生成 `ServerAliveInterval 30` 与 `ServerAliveCountMax 6`，让空闲 SSH 连接通过协议层保活，避免长时间闲置后被网络设备或服务端踢掉。

## [1.161.0] - 2026-07-01

### Added
- 命令搜索新增结构化查询 token，支持 `risk:`、`lifecycle:` 和 `boundary:` 按命令风险等级、生命周期状态和边界可信度过滤命令块，并保留普通全文词组合搜索。

## [1.160.0] - 2026-07-01

### Changed
- 设置窗口和关于窗口打开或重新唤起时会在屏幕居中，并清空初始 focus 状态；设置窗口默认高度略增，减少底部内容的压迫感。

## [1.159.0] - 2026-07-01

### Added
- 结构化命令块新增 `commandRiskLevel` 与 `commandRiskReasons`，用 `read_only`、`mutating`、`dangerous`、`unknown` 和稳定原因码描述命令风险画像，并同步到 AI 上下文、CLI/MCP 命令块快照、最近失败诊断和 Runbook 导出。

## [1.158.0] - 2026-07-01

### Added
- 结构化命令块新增 `commandLifecycleState`，用 `running`、`succeeded`、`failed`、`interrupted`、`superseded` 和 `completed_unknown_status` 稳定描述命令生命周期，并同步到 AI 上下文、CLI/MCP 命令块快照、最近失败诊断和 Runbook 导出。

## [1.157.0] - 2026-07-01

### Added
- 结构化命令块新增 `commandBoundaryReasons`，用 `shell_integration_start`、`process_exit_completion`、`command_still_running` 等稳定 reason code 解释 `commandBoundaryConfidence` 的来源，并同步到 AI 上下文、CLI/MCP 命令块快照、最近失败诊断和 Runbook 导出。
- 关于页改为独立窗口，并接入系统 App 菜单的“关于 MuseTerm”入口。
- 关于页推荐 App 卡片改为整卡可点击，链接到 83d 的无语言前缀产品页，例如 `https://83d.me/products/musemate`。

## [1.156.0] - 2026-07-01

### Added
- 结构化命令块新增 `commandBoundaryConfidence`，按 `high`、`medium`、`low` 标记命令开始/结束边界的可信度，并同步到 AI 上下文、CLI/MCP 命令块快照、最近失败诊断和 Runbook 导出。
- 设置新增关于页，展示 128px 企鹅 PNG 序列动画、可点击的作者主页 `https://83d.me`，并从 83d 发布清单整理推荐 App 与图标。

### Fixed
- 为设置页显式导入 Combine，确保 `Timer.publish(...).autoconnect()` 在 Xcode 显式模块检查下可编译。

## [1.155.1-rc1] - 2026-07-01

### Fixed
- 从 Xcode 同步构建中排除本地生成资源目录 `museterm/GeneratedAssets/`，避免临时图片被误打进 app bundle 或因同名资源影响测试构建。

## [1.155.0] - 2026-07-01

### Added
- 建议排查动作新增 `confirmationReasons`，用 `context_sensitive_command`、`may_expose_sensitive_context`、`follow_up_may_mutate_state` 和 `repeated_failure_loop_risk` 等稳定 reason code 解释为什么动作只能填入或展示、必须由用户确认，并同步到 AI 上下文、CLI/MCP 快照和 Runbook 导出。

## [1.154.1-rc1] - 2026-07-01

### Added
- 建议排查动作的 `evidenceAnchors` 新增 `retry_pause_decision_anchor_command_id`，在暂停重试决策已锚定最新失败命令块时同步暴露该证据来源，方便 AI/MCP 和 Runbook 解释建议动作为何仍适用于当前失败尝试。

### Fixed
- 移除设置页 App 图标网格中与默认企鹅图标视觉重复的“终端企鹅”选项，保留默认企鹅入口作为唯一企鹅图标。

## [1.153.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseDecisionAnchorCommandID`，将暂停重试建议锚定到最新失败命令块，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，避免外部工具复用过期建议。

### Fixed
- 修复 `Cmd+W` 被系统默认关闭窗口命令抢占的问题：快捷键现在只关闭当前标签，不会在多标签窗口中直接关闭整个 App。
- 关闭仍在运行终端进程的标签前会弹出确认，并支持勾选“以后不再询问”；关闭最后一个标签时会补一个新的本地标签，避免窗口被连带关闭。

## [1.152.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseDecisionRefreshTriggers`，声明暂停决策应在冷却到期、新命令结果或上下文变化时刷新，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.151.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseDecisionReasons`，用稳定 reason code 解释 `retryPauseDecision` 的来源，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.150.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseDecisionConfidence`，为 `retryPauseDecision` 输出 `none`、`medium` 或 `high` 可信度，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.149.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseDecision`，将暂停强度折成 `none`、`inspect_before_retry` 或 `wait_before_retry` 的机器可读下一步决策，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.148.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseUntil`，基于最近失败时间与建议冷却时间输出最早重试时间，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.147.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseCooldownMilliseconds`，按暂停强度输出建议冷却时间，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.146.0] - 2026-07-01

### Added
- 终端文本选择支持边缘自动滚动：鼠标拖拽选区靠近终端视图顶部或底部时，会持续滚动 scrollback 并同步延伸选区，便于一次选中多屏输出。
- 连续同类失败诊断新增 `retryPauseSeverity`，用 `none`、`advisory` 或 `strong` 汇总暂停重试建议强度，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.145.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `retryPauseRecommended` 与 `retryPauseReasons`，在立即重试、重试加速或上下文稳定时输出暂停重试建议原因，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.144.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `latestIntervalTrend`，基于最近失败间隔和平均失败间隔输出 `accelerating`、`steady` 或 `slowing`，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，方便判断重试是否正在加速。

## [1.143.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `latestIntervalMilliseconds`，记录最近两次连续失败之间的间隔，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，方便判断用户刚才是否又在短时间内重试。

## [1.142.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `cadence`，把平均失败间隔归类为 `immediate_retry`、`rapid_retry` 或 `spaced_retry`，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，方便外部工具直接判断重复失败节奏。

## [1.141.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `averageIntervalMilliseconds`，基于连续失败时间窗和次数计算平均失败间隔，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，方便判断失败是否来自短时间密集重试。

## [1.140.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `contextStability`，用 `stable`、`command_changed`、`working_directory_changed` 或 `command_and_working_directory_changed` 汇总重复失败窗口的上下文状态，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.139.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `contextChangeReasons`，用稳定 reason code 标明重复失败期间是命令变化、工作目录变化，还是两者都变化，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出。

## [1.138.0] - 2026-07-01

### Added
- 连续同类失败诊断现在会记录窗口内全部命令块 ID、唯一命令、唯一工作目录和 `contextChanged` 标记，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，方便外部工具判断重复失败期间上下文是否已经变化。

## [1.137.0] - 2026-07-01

### Added
- 连续同类失败诊断现在会记录首次与最近重复失败命令文本，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出；命令文本会沿用敏感信息脱敏策略，方便复盘时直接看见重复失败窗口两端执行的具体命令。

## [1.136.0] - 2026-07-01

### Added
- 连续同类失败诊断现在会记录首次与最近重复失败命令在 `outputTail` 中的行号和证据文本，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，方便复盘时直接定位重复失败窗口两端的原始输出证据。

## [1.135.0] - 2026-07-01

### Added
- 连续同类失败诊断现在会记录首次与最近重复失败命令块 ID 及其工作目录，并同步到 AI 上下文、MCP/CLI 快照和 Runbook 导出，方便外部工具把连续失败窗口精确关联回原始命令块。

## [1.134.0] - 2026-07-01

### Added
- 命令诊断摘要现在会记录最近失败命令和最近失败诊断对应的工作目录，并同步到 AI 上下文、MCP/CLI 快照、Runbook 导出和建议动作证据锚点，方便外部工具判断失败发生在哪个项目上下文。

## [1.133.0] - 2026-07-01

### Added
- 命令诊断摘要现在会携带最近失败命令和最近失败诊断对应的 `CommandBlock` ID，并同步到 AI 上下文、MCP/CLI 快照、Runbook 导出和建议动作证据锚点，方便外部工具把诊断精确关联回原始结构化命令块。

## [1.132.0] - 2026-07-01

### Added
- 失败命令诊断现在会记录最近失败诊断在结构化 `outputTail` 中的行号与原始证据行，AI 上下文、MCP/CLI 快照和 Runbook 导出都会携带该证据，便于后续搜索、复盘和解释时定位“这条判断来自哪一行输出”。

## [1.131.0] - 2026-07-01

### Changed
- 收紧终端右键选区的无效 Web URL 兜底：`http://localhost:70000` 这类带 `http://` 或 `https://` 但端口无效的文本不再被当成路径或 `rg` 搜索动作，避免无效 URL 同时误触路径菜单。

## [1.130.0] - 2026-07-01

### Changed
- 收紧终端右键选区的 host:port 识别：`Foo.swift:42`、`users_controller.rb:12:8` 等常见文件行号不再被误当成 URL/端口，真实 `example.com:8080` 和 `localhost:3000` 仍保持端口动作。

## [1.129.0] - 2026-07-01

### Changed
- 收紧终端右键选区的 `rg` 搜索填入动作：URL、明确端口、PID、Git hash、JSON 和过长单行文本不再额外展示 `rg` 动作，减少结构化选区菜单噪音。

## [1.128.0] - 2026-07-01

### Changed
- 终端右键路径菜单现在会静态还原简单单引号和反斜杠转义路径，已存在的本机目录即使选区形如 `'path with space'` 或 `path\ with\ space` 也能显示 Finder 与 `cd` 动作；ANSI-C `$'...'` 形式继续保守跳过。

## [1.127.0] - 2026-07-01

### Changed
- 收紧终端右键选区的 Base64 解码动作：只有长度、字符集、padding 和可打印 UTF-8 内容都可信时才展示解码结果，减少普通短文本误触转换动作。

## [1.126.0] - 2026-07-01

### Changed
- 收紧终端右键选区的端口识别：`:3000` 和 `localhost:3000` 等明确端口仍会触发端口动作，裸数字优先作为 PID 处理，避免同一选区同时出现端口和 PID 子菜单。

## [1.125.0] - 2026-07-01

### Changed
- 收紧终端右键选区的路径识别：普通短句和语义化版本号不再触发路径子菜单，明确路径、已存在本机路径、shell 转义路径和文件名式选区仍会提供路径动作。

## [1.124.0] - 2026-07-01

### Changed
- 终端右键路径删除动作改为填入 `rm -i --`，让 shell 在真正删除前再要求交互确认；动作仍不会自动回车执行。

## [1.123.0] - 2026-07-01

### Added
- 终端右键路径子菜单新增 Finder 显示和 `rm -i --` 填入动作；删除命令只写入终端输入区，仍需用户手动确认执行。

## [1.122.0] - 2026-07-01

### Added
- CLI/MCP 的 `screen --json`、`history --json`、`commands`、`read_screen metadata:true`、`read_history metadata:true` 和 `read_commands` 顶层 payload 新增 `app` 与 `version`，外部工具读取屏幕、历史或命令块时可直接判断 App 来源和版本。
- 终端右键选区菜单新增脱敏复制、Markdown 代码块、AI 解释提示词、URL、路径、端口、PID、Git hash、JSON 和常见编码转换动作；危险类动作仍只填入命令，等待用户确认执行。

## [1.121.1-rc1] - 2026-07-01

### Fixed
- 修复终端右键菜单中“转义键入所选路径”在菜单打开时因选区读取时机不稳定而被置灰的问题；菜单项现在保持可点击，点击时再读取选区并在无可用选区时给出系统反馈。

## [1.121.0] - 2026-07-01

### Added
- CLI/MCP 的 `screen --json`、`history --json`、`read_screen metadata:true` 和 `read_history metadata:true` 顶层 payload 新增 `selectedTabID`，外部工具读取屏幕或历史时可判断返回内容来自当前选中标签还是指定的其他标签。

## [1.120.0] - 2026-07-01

### Added
- CLI/MCP 的 `screen --json`、`history --json`、`commands`、`read_screen metadata:true` 和 `read_commands` 顶层 payload 新增 `currentDirectory`，外部工具读取具体屏幕、历史或命令块时可同时拿到当前 shell 与工作目录。

## [1.119.0] - 2026-07-01

### Added
- CLI/MCP 的 `screen --json`、`history --json`、`commands`、`read_screen metadata:true` 和 `read_commands` 顶层 payload 新增 `shellName`，外部工具读取具体屏幕、历史或命令块时无需先调用 `list_tabs` 也能知道当前 shell 环境。

## [1.118.0] - 2026-07-01

### Added
- CLI/MCP 标签快照新增 `shellName` 字段，`list_tabs metadata:true` 可直接返回当前标签探测到的 zsh、bash、fish 等 shell 名，方便外部 AI 工具按 shell 环境解释命令和生成建议。

### Changed
- 将本机端口扫描、`lsof` 字段解析、服务名识别和搜索匹配模型从 `TaskPortPanel.swift` 拆分到 `LocalServiceScanner.swift`，任务与端口面板重新保持在 2000 行以内。

### Fixed
- 修复任务与端口面板中 `lsof` 返回的中文进程名或中文工作目录被显示成 `\xNN` 字节转义的问题；端口搜索现在也会使用还原后的中文文本匹配。

## [1.117.0] - 2026-07-01

### Added
- 任务与端口面板新增本机监听端口过滤搜索，可按进程名、PID、监听地址、端口号、常见服务名和进程工作目录匹配，端口行会显示服务名 badge 与工作目录名。

### Changed
- 当前会话工具里的 PID 输入框改为“用于操作的 PID”，避免和端口过滤搜索混淆。

## [1.116.0] - 2026-07-01

### Added
- 本地会话会记录登录 shell 名；SSH 启动时先发送轻量 shell 探测 marker，回传 `$SHELL` 后归一化为 `zsh` / `bash` / `fish` 等稳定 shell 名，并补充 parser 与 session 测试。
- 侧栏标签行会在目录/远端摘要前显示轻量 shell badge，帮助区分 zsh、bash、fish 等会话；侧栏顶部工具按钮分到第二行，避免标题与按钮在窄宽度下互相挤压。

### Changed
- 侧栏标题区改为两行布局，`MuseTerm` 应用名固定单行显示，避免被工具按钮挤压成竖排导致侧栏变形。
- 将 `TerminalShellArgumentEscaper` 的单元测试拆分到独立 `TerminalShellArgumentEscaperTests.swift`，让路径参数转义行为与多行/高危输入分析测试分离。

## [1.115.0] - 2026-07-01

### Changed
- 将 `TerminalShellArgumentEscaper` 从 `TerminalSafetyInputAnalyzer.swift` 拆分到独立文件，路径参数转义逻辑与多行/高危输入分析分离，现有转义测试继续覆盖行为不变。

## [1.114.0] - 2026-07-01

### Changed
- `TerminalShellIntegrationParser` 现在同时支持 BEL 与 `ESC \\` 两种 OSC marker 终止符，并补充跨数据块 ST 终止、BEL/ST 混合 marker 的测试。

## [1.113.0] - 2026-07-01

### Added
- 为 `TerminalShellIntegrationParser` 补充边界测试，覆盖 marker 前缀跨 PTY 数据块拆分、无效 marker 后继续解析后续有效 marker，以及普通终端输出不产生 shell integration 事件。

## [1.112.0] - 2026-07-01

### Added
- 终端右键菜单新增“转义键入所选路径”，可将当前选中文本作为 shell 参数填入命令行；普通文件名会单引号转义，已有 `$'...'` / 反斜杠转义形式会原样保留，便于处理包含奇怪字符或转义字节的文件名。

### Changed
- 将 `TerminalShellIntegrationParser` 从 `TerminalHostView.swift` 拆分到独立文件，后续增强 shell marker 解析时不再继续挤压终端宿主视图。

## [1.111.0] - 2026-07-01

### Changed
- 多行粘贴确认会识别 MuseTerm 远端 SSH 命令追踪初始化脚本，并改用专门的标题、说明和“启用追踪”按钮，解释临时 shell hook 的用途、边界和失效条件。
- 测试直接使用真实远端 shell integration 初始化脚本验证专用确认文案，并覆盖类 marker 普通粘贴不会误用追踪文案。

## [1.110.0] - 2026-07-01

### Changed
- 将多行粘贴确认说明的文案组装沉入 `SafetyInputAnalyzer.multilinePasteConfirmationMessage(for:)`，弹窗实现复用同一入口。
- 新增测试覆盖多行粘贴确认说明必须同时包含非空行数提示、触发原因和段落分隔。

## [1.109.0] - 2026-07-01

### Added
- `CommandBlockDiagnostics` 新增 `latestFailedCommandStartSource`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 会同步暴露最近失败命令开始来源。
- 测试覆盖 CLI/MCP 诊断快照、Runbook 和 AI 上下文里的最近失败命令开始来源字段。

### Changed
- 多行粘贴确认弹窗新增触发原因说明，提示多行 shell 文本发送到终端后可能连续执行命令，用户需确认预览符合预期后再发送。

## [1.107.0] - 2026-07-01

### Added
- `CommandBlockDiagnostics` 新增 `latestFailedCompletionSource`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 会同步暴露最近失败命令完成来源。
- 测试覆盖 CLI/MCP 诊断快照、Runbook 和 AI 上下文里的最近失败完成来源字段。

## [1.106.0] - 2026-07-01

### Added
- `CommandBlockDiagnostics` 新增 `latestFailedDurationMilliseconds`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 会同步暴露最近失败命令耗时。
- 测试覆盖 CLI/MCP 诊断快照和 AI 上下文里的最近失败耗时字段。

## [1.105.0] - 2026-07-01

### Added
- `CommandBlockDiagnostics` 新增 `latestFailedExitCode`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 会同步暴露最近失败命令退出码。
- 测试覆盖 CLI/MCP 诊断快照和 AI 上下文里的最近失败退出码字段。

## [1.104.0] - 2026-07-01

### Changed
- 将 Runbook Markdown 导出、诊断摘要写入、回放脚本生成和路径变量参数化从 `ContentView.swift` 拆分到 `RunbookMarkdownExporter.swift`。
- `ContentView.swift` 行数进一步降到约 1200 行，主视图继续聚焦交互编排，Runbook 产物生成逻辑独立维护。

### Added
- 新增 `RunbookMarkdownExporterTests`，覆盖回放脚本路径参数化、逐步确认包装、敏感命令参数脱敏和空命令过滤。

## [1.103.0] - 2026-07-01

### Changed
- 将 `RunbookSensitiveRedactor` 从 `ContentView.swift` 拆分到独立的 `RunbookSensitiveRedactor.swift`，让敏感信息脱敏策略可独立维护和测试。
- 扩展脱敏规则，覆盖 GitHub fine-grained token、Google API Key、npm token、Stripe 风格 key、命令行 `--token` / `--password` 参数、URL basic-auth 密码和 PEM 私钥块。

### Added
- 新增 `RunbookSensitiveRedactorTests`，覆盖常见 Provider token、命令行密钥参数、URL 凭据、PEM 私钥块和普通输出不误报。

## [1.102.0] - 2026-07-01

### Changed
- 将 AI Explain Provider 配置校验、OpenAI/Anthropic/Gemini 兼容流式请求和响应解码从 `ContentView.swift` 拆分到 `AIExplainClient.swift`。
- `ContentView.swift` 行数降到 2000 行以下，主视图文件继续聚焦面板组合、搜索交互和 Runbook 操作编排。

### Added
- 新增 `AIExplainClientTests`，覆盖 AI Explain 配置缺少模型、缺少 Base URL，以及 Ollama 空 API Key 可用的本地校验路径。

## [1.101.0] - 2026-07-01

### Changed
- 将安全输入分析、内置高危命令规则、自定义规则解析和确认预览控件从 `TerminalHostView.swift` 拆分到 `TerminalSafetyInputAnalyzer.swift`。
- `TerminalHostView.swift` 行数降到 2000 行以下，终端宿主视图继续聚焦 PTY 生命周期、输入输出与 shell integration 编排。

### Added
- 新增 `TerminalSafetyInputAnalyzerTests`，覆盖多行粘贴识别、内置高危命令规则、自定义文本/正则规则和长文本预览截断。

## [1.100.0] - 2026-07-01

### Changed
- 将每日命令统计的 `PersistentCommandStatsSnapshot` 与 `PersistentCommandStatsStore` 从 `TaskPortPanel.swift` 拆分到独立的 `PersistentCommandStatsStore.swift`。
- `TaskPortPanel.swift` 行数降到 2000 行以下，面板文件继续聚焦任务、端口与统计展示，统计持久化逻辑独立维护。

## [1.99.0] - 2026-07-01

### Changed
- 将 `CommandDiagnosticAction` 及其稳定 action code 枚举从 `TaskPortPanel.swift` 拆分到独立的 `CommandDiagnosticAction.swift`，让诊断动作契约和面板实现解耦。
- `TaskPortPanel.swift` 行数从 2400+ 降到约 2000 行，后续继续深化诊断契约时可以在独立模型文件中维护，减少主面板文件膨胀。

## [1.98.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultCaveats`，用稳定 code 描述建议命令结果的适用局限，例如本机端口扫描只覆盖当前网络命名空间、PATH 只代表当前 shell、Git status 需要位于仓库内。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果局限提示，帮助外部工具避免把只读检查结果过度推广到容器、远端、其他 shell 或后续已变化的上下文。

## [1.97.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultDecisionHints`，用稳定 code 描述建议命令结果应触发的保守决策分支，例如端口 owner 需要用户决定、权限不匹配需要明确提权、Git dirty 状态需要先处理工作树。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果决策提示，让外部工具在解析和解释输出后仍保持“只建议、不越权”的执行边界。

## [1.96.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultParsingHints`，用稳定 code 描述建议命令输出应如何解析，例如按行文本、空白分隔列、PATH 列表、组合命令输出、目录列表、Git porcelain 状态或可选 Git 输出。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果解析提示，帮助外部工具先稳定拆解输出，再应用解释、脱敏和复用策略。

## [1.95.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultInterpretationHints`，用稳定 code 描述建议命令输出应如何解释，例如空端口列表表示本机无监听者、权限输出需要比较用户与权限位、Git dirty 状态需要用户决策。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果解释提示，帮助外部工具少依赖自然语言猜测排查结果含义。

## [1.94.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultReuseValidationChecks`，用稳定 code 描述复用历史建议命令结果前应完成的机器可读检查，例如刷新动态快照、匹配工作目录、Shell 环境、用户身份、Git 状态或失败指纹。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果复用验证检查，让外部工具在复用历史诊断前有明确的验证清单。

## [1.93.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultReusePolicy`，用稳定 code 明确建议命令结果应先刷新再用、仅在复用键匹配时可用，还是不能跨失败尝试复用。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果复用策略，帮助外部工具在读取历史诊断结果时选择刷新、保守复用或重新取证。

## [1.92.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultReuseKeyFields`，用稳定 code 声明复用建议命令结果前应比较的上下文字段，例如终端会话、工作目录、Shell 环境、Git 仓库、监听端口、权限元数据或失败指纹。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果复用键字段，帮助外部工具避免把不同目录、环境、仓库或失败场景的历史诊断结果混用。

## [1.91.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultFreshnessPolicy`，用稳定 code 声明建议命令结果是实时快照、上下文绑定，还是仅对当前失败尝试有效。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果新鲜度策略，帮助外部工具在复用历史诊断结果前判断是否必须重新取证。

## [1.90.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultValidityScope`，用稳定 code 声明建议命令结果可在哪个范围内复用，例如当前终端会话、网络命名空间、工作目录、Shell 环境或 Git 仓库。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果适用范围，帮助外部工具避免把本地、远端、目录或仓库上下文混用。

## [1.89.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultRefreshTriggers`，用稳定 code 声明哪些上下文变化会让建议命令结果过期，例如进程、监听端口、工作目录、权限、PATH、文件系统或 Git 状态变化。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果刷新触发条件，帮助外部工具在重用旧诊断结果前判断是否需要重新取证。

## [1.88.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultRedactionHints`，用稳定 code 提示建议命令结果中应优先脱敏的内容类型，例如路径、用户、进程、监听地址、Git 分支和 upstream。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果脱敏提示，帮助外部工具在摘要、分享或持久化前选择更准确的脱敏策略。

## [1.87.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultRetentionPolicy`，用稳定 code 声明建议命令结果可完整保存、只能保存脱敏摘要，还是仅保留在本机会话。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果保留策略，帮助外部工具在记录日志或建立索引前遵守更细的隐私边界。

## [1.86.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultSharingPolicy`，用稳定 code 声明建议命令结果应直接分享、先脱敏再分享，还是仅本地查看。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果分享策略，让外部工具在转发诊断结果前能遵守更明确的隐私边界。

## [1.85.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `resultPrivacyLevel`，用稳定 code 汇总建议命令结果的隐私敏感级别。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露结果隐私级别，帮助外部工具在解释、转发或日志记录前选择本地处理或脱敏策略。

## [1.84.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `sensitiveResultFields`，用稳定 code 标明建议命令结果中哪些字段可能携带路径、用户、进程、Git 或目录元数据等敏感上下文。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露敏感结果字段，帮助外部工具在解释或转发结果前优先脱敏。

## [1.83.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `expectedResultSignals`，用稳定 code 标明建议命令输出中哪些信号代表只读检查已拿到可用证据。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露预期结果信号，帮助外部工具判断建议命令输出是否足够支撑下一步决策。

## [1.82.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `expectedResultFields`，用稳定 code 标明建议命令结果中应重点抽取的字段，例如端口、PID、进程名、当前用户、目录权限、PATH 条目、Git 分支和 dirty 状态。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露预期结果字段，帮助外部工具按字段理解建议命令输出。

## [1.81.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `expectedResultKind`，用稳定 code 标明建议命令预期产出的结果类型，例如监听端口列表、身份与权限信息、PATH、目录列表、Git 状态或上下文快照。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露预期结果类型，便于外部工具按结果形态解释后续输出。

## [1.80.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `actionScope`，用稳定 code 标明建议动作主要检查的上下文面，例如本地网络、权限边界、shell 环境、工作目录、Git 仓库或连续失败上下文。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露动作作用域，帮助外部工具区分“在哪里执行”和“在排查什么”。

## [1.79.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `evidenceAnchors`，用稳定 code 标明建议动作锚定的诊断证据来源。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露证据锚点，帮助外部工具解释建议来源而不重复携带敏感日志内容。

## [1.78.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `completionCriteria`，用结构化清单说明建议排查动作何时可以收口。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露完成判据，帮助工具和用户判断这一轮排查是否已有足够证据停止或进入下一步。

## [1.77.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `userDecisionPoints`，用结构化清单说明哪些判断必须交给用户拍板。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露用户决策点，例如是否停进程、提权、安装依赖、恢复文件或处理 Git 状态。

## [1.76.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `executionTarget`，用稳定 code 声明建议命令应在当前终端会话、工作目录、shell 环境、Git 仓库或网络命名空间中理解。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露执行目标，降低本地、远端、容器或错误目录中误用建议命令的风险。

## [1.75.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `automationGuardrails`，用结构化清单声明建议动作不能自动越过的边界。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露自动化护栏，例如禁止自动 `kill`、`sudo/chmod`、安装依赖或执行 Git 破坏性操作。

## [1.74.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `preflightChecks`，用结构化清单描述填入建议排查动作前应确认的上下文。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露执行前检查，继续强化建议动作只读、分阶段和用户确认的安全边界。

## [1.73.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `retryCondition`，用稳定 code 描述用户考虑重跑失败命令前应满足的条件。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露重试条件，帮助外部工具把排查动作和后续重跑边界串起来。

## [1.72.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `executionMode`，当前建议动作统一标记为 `stage_only`，明确只能填入或展示，不能由外部工具自动执行。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露执行模式，进一步固定“用户确认后执行”的安全边界。

## [1.71.0] - 2026-07-01

### Added
- `suggestedNextAction` 新增 `priorityScore` 与 `priorityFactors`，让单个建议排查动作也能独立说明排序权重和原因。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露建议动作优先级字段，减少外部工具拼接父级诊断字段的成本。

## [1.70.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `diagnosticPriorityFactors`，用稳定 reason code 解释 `diagnosticPriorityScore` 的来源，例如失败命令、严重级别、诊断分类、可信度和连续失败次数。
- Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 快照会同步暴露诊断优先级因素，便于外部工具解释和筛选高优先级失败。

## [1.69.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `diagnosticPriorityScore`，按失败严重级别、诊断分类、分类可信度和连续失败次数生成 0-100 的稳定优先级分数。
- AI 上下文与 CLI/MCP `commandDiagnostics` 快照会同步暴露诊断优先级分数，便于外部工具按排查优先级排序。

## [1.68.0] - 2026-07-01

### Added
- MCP `send_text` 与 `send_key` 支持 `timeout` 和 `metadata` 参数；默认仍返回短消息，`metadata: true` 时返回完整工具 response 元数据。
- 新增 MCP `send_text` 真实 JSON-RPC 端到端测试，模拟 App response 文件并验证响应元数据。

## [1.67.0] - 2026-07-01

### Added
- `museterm input` 与 `museterm key` 支持 `--timeout SECONDS`，脚本可按场景延长或缩短等待 App response 文件的时间；超时时间必须为正数。
- CLI 输入请求端到端测试覆盖 `--timeout` 与 `--json` 同时使用的请求链路。

## [1.66.0] - 2026-07-01

### Added
- `museterm input` 与 `museterm key` 支持 `--json`，可输出完整工具 response 元数据；默认短消息输出保持兼容。
- 新增 CLI 输入请求端到端测试，模拟 App response 文件并验证 `input --json` 会返回响应元数据。

## [1.65.0] - 2026-07-01

### Added
- 工具请求响应新增 `schemaVersion`、App 名称、版本、`snapshotSequence`、`action` 和成功目标 `tabID`，方便直接消费 response 文件的外部工具定位请求处理环境。
- 新增工具响应编码测试，锁定请求响应元数据契约。

## [1.64.0] - 2026-07-01

### Added
- 工具状态快照新增单调递增的 `snapshotSequence`，每次写入 `state.json` 时递增，方便外部工具判断轮询时是否读到新快照。
- `museterm tabs`、`museterm screen --json`、`museterm history --json`、`museterm commands` 以及对应 MCP 元数据响应会透传 `snapshotSequence`，减少外部工具依赖时间字符串判断状态新旧。

## [1.63.0] - 2026-07-01

### Added
- `museterm commands` 与 MCP `read_commands` 顶层新增 `tabID`、`selectedTabID`、`commandCount`、`returnedCommandCount` 和 `outputTailLimit`，让外部工具读取命令块时无需自行推断标签来源和截断参数。
- 新增 MCP `read_commands` 真实 JSON-RPC 端到端测试，覆盖命令块顶层元数据和输出尾部截断元数据。

## [1.62.0] - 2026-07-01

### Added
- MCP `list_tabs` 支持 `metadata: true`，返回 `schemaVersion`、App 名称、版本、选中标签 ID 和标签数组；默认数组输出保持兼容。
- 新增真实 JSON-RPC 端到端测试，验证外部工具可通过 MCP 读取标签列表元数据。

## [1.61.0] - 2026-07-01

### Changed
- MCP `read_screen metadata:true` 新增真实 JSON-RPC 端到端测试，验证外部工具路径能读取屏幕截断元数据。

## [1.60.0] - 2026-07-01

### Added
- `museterm screen --json` 与 `museterm history --json` 会返回文本、字符数、返回字符数、截断上限和截断状态；MCP `read_screen` / `read_history` 也支持 `metadata: true` 返回同样的 JSON 元数据。

## [1.59.0] - 2026-07-01

### Added
- `museterm commands` / MCP `read_commands` 的命令块新增 `outputTailReturnedCharacters` 和 `outputTailStoredTruncated`，区分返回 tail 的长度与 App 内部保存的 tail 是否已相对完整输出截断。

## [1.58.0] - 2026-07-01

### Changed
- `museterm commands` / MCP `read_commands` 的 `outputTailLimit` 现在以数字或 `null` 输出，避免外部工具把截断上限当字符串处理。
- CLI 命令读取新增真实 Ruby 脚本端到端测试，覆盖 `commands --chars` 的输出截断元数据。

## [1.57.0] - 2026-07-01

### Added
- `museterm commands` 和 MCP `read_commands` 返回的每个命令块新增 `outputTailCharacters`、`outputTailLimit` 和 `outputTailTruncated`，让外部工具知道输出尾部是否因 `--chars` 被截断。

## [1.56.0] - 2026-07-01

### Added
- `museterm tabs`、`museterm commands` 和 MCP `read_commands` 响应会透传顶层 `schemaVersion`，外部工具无需读取原始状态文件也能判断 JSON 契约版本。

## [1.55.0] - 2026-07-01

### Added
- CLI/MCP 状态快照新增顶层 `schemaVersion`，命令诊断快照新增 `schemaVersion`，方便外部工具判断 JSON 契约版本。

### Changed
- 工具桥快照编码测试显式运行在 MainActor 上，消除 Swift 6 对主线程快照编码隔离的预警。

## [1.54.0] - 2026-07-01

### Added
- 结构化建议排查动作新增 `fallbackNextSteps`，记录观察不到预期信号时的只读降级排查方向。
- Runbook、AI 上下文和 CLI/MCP `diagnostics.suggestedNextAction` 会同步暴露降级步骤，让失败排查从“下一条命令”延展为可复盘的小路径。
- 规划文档补充 SwiftTerm 可行性决策矩阵、实现层分工、优先落地口径和 MVP 验证清单，明确哪些 terminal 设想由 SwiftTerm 支撑、哪些应由 MuseTerm 外层实现。

## [1.53.0] - 2026-07-01

### Added
- 结构化建议排查动作新增 `expectedSignals`，记录执行只读排查命令后应该重点观察的信号。
- Runbook、AI 上下文和 CLI/MCP `diagnostics.suggestedNextAction` 会同步暴露观察信号，便于把排查建议沉淀成可复盘步骤。

## [1.52.0] - 2026-07-01

### Added
- 结构化建议排查动作新增 `sourceCategory` 和 `confidence`，让单个 action 对象也能说明建议来自哪类诊断以及可信度。
- Runbook、AI 上下文和 CLI/MCP `diagnostics.suggestedNextAction` 会同步暴露来源分类和可信度，减少外部工具拼接旁路字段的成本。

## [1.51.0] - 2026-07-01

### Added
- 结构化建议排查动作新增稳定 `id`，例如 `inspect_git_state`、`inspect_repeat_context`，方便 CLI/MCP 和后续 UI 自动化按动作类型消费。
- Runbook 和 AI 上下文会同步记录建议动作 ID，避免外部工具依赖可变标题文案做判断。

## [1.50.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `suggestedNextAction`，把建议排查步骤结构化为标题、原因、命令、安全级别和是否需要用户确认。
- Runbook、AI 上下文和 CLI/MCP `diagnostics` 会同步暴露结构化建议动作，同时保留旧的 `suggestedNextCommand` 字段以兼容现有调用方。

## [1.49.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `diagnosticCategoryConfidence`，用 `high` / `medium` / `low` 标记诊断分类的可信度。
- Runbook、AI 上下文和 CLI/MCP `diagnostics` 会同步暴露诊断分类可信度，便于外部工具区分明确错误命中、上下文推断和保守兜底。

## [1.48.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `diagnosticCategoryEvidence`，记录诊断分类命中的脱敏证据文本，便于 AI/MCP 和 Runbook 判断分类来源。
- Runbook、AI 上下文和 CLI/MCP `diagnostics` 会同步暴露诊断分类依据，避免外部工具只能看到分类结果却不知道判断依据。

## [1.47.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `diagnosticCategory`，把最近失败归类为端口占用、权限、缺文件、命令缺失、Git、连续失败或通用问题。
- Runbook、AI 上下文和 CLI/MCP `diagnostics` 会同步暴露诊断分类，建议排查命令也改为复用同一套分类结果。

## [1.46.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `suggestedNextCommand`，为最近失败、连续失败和常见错误类型提供保守的下一步排查命令候选。
- Runbook、AI 上下文和 CLI/MCP `diagnostics` 会同步暴露建议排查命令，外部工具可填入终端等待用户确认执行。

## [1.45.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `matchKind`，区分完全相同的 `exact` 重复与归一化指纹命中的 `normalized` 同类失败。
- Runbook、AI 上下文和 CLI/MCP `diagnostics` 会暴露连续失败匹配方式，便于外部工具判断诊断聚合可信度。

## [1.44.0] - 2026-07-01

### Added
- 连续同类失败诊断新增 `durationMilliseconds`，Runbook、AI 上下文和 CLI/MCP `diagnostics` 可直接读取这波失败持续了多久。
- Runbook Markdown 会记录连续失败持续时长，为后续排查排序、趋势统计和回放摘要打基础。

## [1.43.0] - 2026-07-01

### Added
- 连续同类失败诊断新增首末发生时间，Runbook、AI 上下文和 CLI/MCP `diagnostics` 可直接看到这波失败的时间窗口。
- `RepeatedFailureDiagnostic` 会记录 `firstOccurredAt` 与 `latestOccurredAt`，为后续失败趋势、回放和排查排序打基础。

## [1.42.0] - 2026-07-01

### Added
- 命令诊断摘要新增失败指纹，Runbook、AI 上下文和 CLI/MCP `diagnostics` 可读取归一化后的最近失败特征。

### Changed
- 连续同类失败判断改为基于脱敏后的归一化指纹，URL、路径、hash 和数字变化不会再打断同类失败识别。

## [1.41.0] - 2026-07-01

### Added
- 命令诊断摘要新增 `diagnosticSeverity`，将无失败、普通失败、连续失败和关键失败归类，便于 Runbook、AI 上下文与 CLI/MCP 工具快速判断排查优先级。
- Runbook Markdown 会记录诊断严重级别，AI 当前过滤上下文和 CLI/MCP `diagnostics` 会同步暴露同一字段。

## [1.40.0] - 2026-07-01

### Added
- 命令诊断摘要新增失败命令数、最近失败命令和建议下一步查看项，便于 Runbook、AI 上下文和 CLI/MCP 工具直接定位排查入口。
- Runbook Markdown 会记录失败命令数、最近失败命令和建议下一步查看项，并继续沿用脱敏策略。

### Changed
- 任务统计的失败数改为复用 `CommandBlockDiagnostics.failedCommandCount`，进一步减少诊断逻辑分叉。

## [1.39.0] - 2026-07-01

### Added
- CLI/MCP 的命令读取结果新增 `diagnostics` 摘要，包含最近失败诊断与连续同类失败信息，便于外部工具直接消费结构化故障线索。
- 工具状态文件的 tab snapshot 新增 `commandDiagnostics` 字段，与应用内统计、Runbook 和 AI 上下文复用同一套诊断判断。

### Changed
- `museterm commands` 与 MCP `read_commands` 返回包含 `diagnostics` 和 `commands` 的 JSON 对象，不再只返回命令数组。

## [1.38.0] - 2026-07-01

### Added
- Runbook Markdown 导出会记录最近失败诊断与连续同类失败次数，并沿用脱敏开关处理 token、API Key 与 password 等敏感形态。
- AI Explain 的“当前过滤结果”上下文新增会话诊断摘要，可把最近失败与连续同类失败线索一起交给模型分析。

### Changed
- 连续失败判断抽为可复用的 `CommandBlockDiagnostics`，任务统计、Runbook 与 AI 上下文共享同一套判定逻辑。

## [1.37.0] - 2026-07-01

### Added
- 任务与端口面板新增连续同类失败提醒：最近连续 3 次以上同一诊断失败时，会显示重复次数和脱敏后的诊断行。
- 连续失败检测只关注最近连续已结束命令，若最新命令已成功或诊断不同则不会提示，避免零星失败造成噪音。

## [1.36.0] - 2026-07-01

### Added
- 任务与端口面板的本次会话统计新增最近失败诊断行，优先展示最近已结束失败命令的结构化错误/警告/堆栈等线索。
- 最近失败诊断会在统计模型中脱敏，避免 token、API Key、password 等敏感形态进入面板文本。

## [1.35.0] - 2026-07-01

### Added
- 命令搜索卡片会优先使用结构化输出摘要展示洞察标签，即使输出尾部为空或被截断也能保留关键线索。
- 失败命令卡片会直接展示首条关键诊断行，优先显示错误，其次回退到警告、堆栈、路径、URL 或 commit 线索。

## [1.34.0] - 2026-07-01

### Added
- Runbook Markdown 导出会为带有紧凑输出摘要的命令块写入“输出摘要”段，记录洞察类型、错误/警告、URL、路径、commit 和堆栈线索。
- Runbook 输出摘要复用现有脱敏开关，导出时会隐藏摘要中的常见 token、API Key、password 和密钥形态。

## [1.33.0] - 2026-07-01

### Added
- 结构化命令块新增紧凑输出摘要字段，沉淀洞察类型、首个错误/警告、URL、文件路径、commit hash 和堆栈线索。
- CLI/MCP 命令块快照同步暴露输出摘要，AI 上下文和搜索文本可直接使用已沉淀的关键线索。

## [1.32.0] - 2026-07-01

### Added
- Shell integration 新增命令开始 marker：本地 zsh/fish 和远端 zsh 会在命令真正执行前回传命令文本，结构化命令块可记录命令来源。
- CLI/MCP 命令块快照同步暴露命令开始来源，AI 上下文和搜索文本也会包含该边界可信度线索。

## [1.31.0] - 2026-07-01

### Added
- 结构化命令块新增完成来源字段，可区分 shell hook 退出码、进程退出兜底、用户中断、被下一条命令覆盖和未知来源。
- CLI/MCP 命令块快照同步暴露完成来源，AI 上下文和搜索文本也会包含该可信度线索。

## [1.30.0] - 2026-07-01

### Added
- 命令块输出新增轻量洞察识别，可标记错误、警告、URL、文件路径、JSON、YAML、堆栈和 commit hash。
- 命令块卡片新增“复制有意义的输出摘要”入口，按洞察类型提取关键片段；JSON 输出会在摘要中附带格式化后的 pretty JSON。

## [1.29.0] - 2026-06-30

### Added
- 命令搜索面板新增当前标签滚屏历史搜索结果：当查询命中原始终端历史时，会展示脱敏后的历史片段、命中数量，并支持复制片段。
- `TerminalSession` 维护轻量滚屏历史搜索快照，用于覆盖尚未形成结构化命令块的输出。

## [1.28.0] - 2026-06-30

### Added
- SSH profile 新增远端 shell hook 开关，连接后会为远端 bash/zsh 会话临时注入退出码追踪，不写入远端启动文件。
- 任务与端口面板新增当前会话进程工具，可在本地或 SSH 标签中填入端口扫描、进程列表、PID 详情、SIGTERM 和 SIGKILL 命令，仍需用户按回车确认执行。

### Changed
- 本机监听端口的 `kill PID` 操作现在只允许填入本地终端标签，避免当前选中 SSH 标签时误把本机 PID 当作远端 PID 处理。

## [1.27.0] - 2026-06-30

### Added
- 任务与端口面板新增“今天”统计区块，跨 App 重启累计当天已结束命令数、失败数和最长命令耗时。
- 每日统计保存到本机 Application Support 的 `MuseTerm/Stats/daily-command-stats.json`，仅记录本地聚合数据和已计入命令 ID。

## [1.26.0] - 2026-06-30

### Added
- AI Explain 改为流式输出，命令解释会在响应到达时逐步显示，不再等待完整响应结束后一次性渲染。
- OpenAI 兼容接口、Azure OpenAI、OpenRouter、Ollama、自定义 Provider、Anthropic 和 Google Gemini 均使用各自的 SSE 流式接口。

## [1.25.0] - 2026-06-30

### Added
- Runbook 回放脚本新增变量编辑区，可在命令检查面板中覆盖 `RUNBOOK_HOME` 与 `RUNBOOK_WORKDIR` 默认值。
- 复制回放脚本、复制 Runbook 和保存 Markdown 共用同一套变量覆盖值；导出的 Markdown 会记录当前回放变量默认值。

## [1.24.0] - 2026-06-30

### Added
- 新增项目工作区保存与恢复第一版，可通过标签菜单保存当前本地/SSH 标签、选中标签和本地工作目录，并从上次快照恢复。
- 本地 shell 标签恢复时会把 SwiftTerm 进程直接启动到已保存目录；SSH 标签会保存 profile 快照并恢复连接入口。
- 恢复工作区前新增确认弹窗，明确当前标签会被关闭且运行中的进程不会被原样保留。

## [1.23.0] - 2026-06-30

### Added
- 任务与端口面板新增本次会话统计，展示命令数、失败数、运行中命令、监听端口和最长命令耗时。
- 新增轻量成就徽章，基于当前运行期命令块与端口状态展示“十条命令”“零失败”“服务在线”“长任务”等非打扰式提示。

## [1.22.0] - 2026-06-30

### Added
- AI Explain 新增上下文范围选择，可在“只发命令 / 当前块 / 当前过滤结果”之间切换。
- 复制 AI 上下文和直接请求 AI Explain 会共用当前上下文范围；过滤结果模式会带上当前命令块输出和最多 6 条过滤结果摘要，避免把过多历史输出直接发给模型。

## [1.21.0] - 2026-06-30

### Added
- Runbook 回放脚本新增参数化选项，可将本机 Home 和工作目录抽成 `RUNBOOK_HOME` / `RUNBOOK_WORKDIR`，减少脚本里的本机路径固化。
- Runbook 回放脚本新增逐步确认模式，默认用 `run_step` 包装每条命令，执行前逐条询问用户确认；导出的 Markdown 会记录参数化和逐步确认状态。

## [1.20.0] - 2026-06-30

### Added
- 主窗口新增任务与端口右侧面板，可查看当前运行中的结构化命令块和本机监听 TCP 端口。
- 任务与端口面板支持刷新端口列表、打开 `localhost` URL、复制监听地址，并可将 `kill PID` 填入当前终端等待用户回车执行。

## [1.19.0] - 2026-06-30

### Added
- 命令搜索面板会提示当前过滤结果中疑似包含敏感输出的命令数量，并在对应命令卡片上显示警示。
- 开启脱敏时，命令输出展示、复制、Runbook 导出和 AI 上下文均使用脱敏内容；Runbook 也会记录敏感输出数量与脱敏状态。

## [1.18.0] - 2026-06-30

### Added
- SSH profile 新增安全确认策略，可选择继承全局、强制确认或关闭确认。
- 生产环境 profile 默认使用强制确认；输入拦截会按当前 profile 策略解析多行粘贴和高危命令确认开关。

## [1.17.0] - 2026-06-30

### Added
- 行为设置新增自定义高危命令规则，支持普通文本包含匹配、`regex:` 正则匹配和 `#` 注释行。
- 高危命令确认现在会同时检查内置规则和自定义规则，并在确认弹窗中显示具体命中的自定义规则；无效正则会被忽略，不影响终端输入。

## [1.16.0] - 2026-06-30

### Added
- Runbook 导出新增备注、敏感信息脱敏和回放脚本选项，可在 Markdown 中沉淀操作说明并生成可复用命令脚本。
- 命令搜索面板新增复制回放脚本入口，以及单条命令“填入终端待执行”按钮；命令只会填入当前终端，不自动回车执行。
- 敏感信息脱敏同时作用于 Runbook、AI 上下文复制和 AI Explain 请求，覆盖常见 token、API Key、password、Authorization Bearer、AWS/GitHub/OpenAI/Slack/JWT 形态。

## [1.15.0] - 2026-06-30

### Added
- 本地 shell integration 扩展到 bash 与 fish：bash 通过 MuseTerm 生成的 rcfile 在用户启动文件之后挂载 `PROMPT_COMMAND`，fish 通过启动时 source 的 hook 文件挂载 `fish_postexec`。
- bash/fish/zsh 均会输出不可见 MuseTerm OSC marker，用于回填命令块真实退出码，提升失败过滤、Runbook 和 AI Explain 的准确度。

## [1.14.0] - 2026-06-30

### Added
- 命令搜索面板新增真实 AI Explain 调用入口，可直接针对单条命令块请求解释。
- AI Explain 支持 OpenAI 兼容接口、Anthropic、Google Gemini、Azure OpenAI、OpenRouter、Ollama 和自定义端点；Ollama 允许无 API Key，本地/云端密钥只从 Keychain 读取并写入请求，不进入 Runbook、MCP 状态或剪贴板上下文。
- AI Explain 结果面板展示加载、错误和解释结果，并提示命令意图、状态/失败原因、风险和下一步建议。

## [1.13.0] - 2026-06-30

### Added
- 命令搜索面板新增 Runbook 导出入口，可将当前搜索/失败过滤结果生成 Markdown。
- Runbook 支持复制到剪贴板或保存为 `.md` 文件，内容包含标签、目标、环境、生成时间、命令状态、耗时、目录、命令文本和输出尾部。

## [1.12.0] - 2026-06-30

### Added
- SSH profile 新增环境字段，可标记开发、预发、生产环境，并在侧栏与标签行显示环境短标。
- 行为设置新增“多行粘贴前确认”和“高危命令前确认”开关，默认开启。
- 终端输入发送前增加安全确认：多行粘贴会展示预览，高危规则命中时会显示当前环境和命令预览，取消后不会写入 PTY。
- 内置高危命令规则覆盖递归删除、数据库破坏性操作、Kubernetes 删除/排空、Terraform destroy、磁盘擦除、Docker 全量清理和 Git 强制重置。

## [1.11.0] - 2026-06-30

### Added
- 本地 zsh shell 启动时自动安装 MuseTerm 轻量 shell integration，先加载用户原有 zsh 配置，再通过不可见 OSC marker 回传命令结束状态。
- 命令块可根据 shell integration marker 记录真实退出码，失败过滤和 AI 上下文中的状态判断更可靠。

## [1.10.0] - 2026-06-30

### Added
- 主窗口新增右侧命令搜索面板，可查看当前标签最近命令块，按命令、目录和输出搜索，并可仅显示失败命令。
- 命令块卡片新增复制命令、复制输出尾部和复制 AI 上下文入口；AI 上下文包含当前 Provider、模型、Base URL 与命令执行摘要，但不包含 API Key。
- 菜单新增 `Cmd+F` 打开/关闭命令搜索面板。

## [1.9.0] - 2026-06-30

### Added
- 设置新增 AI Provider 分组，支持 OpenAI、Anthropic、Google Gemini、Azure OpenAI、OpenRouter、Ollama 与自定义 OpenAI 兼容端点，并将 API Key 保存到本机 Keychain。
- 新增结构化命令块基础采集：记录用户提交的命令、目录、开始/结束时间、输出尾部、输出字符数和中断/进程退出状态，为后续搜索、Runbook 与 AI Explain 打基础。
- MCP/CLI 状态新增最近命令块，`museterm commands` 与 MCP `read_commands` 可读取结构化命令上下文。

### Changed
- 忽略仓库内 `.local-derived-data/` 构建缓存，避免本地 Xcode 验证产物进入版本库。

## [1.8.1-rc1] - 2026-06-30

### Changed
- 左侧标签行的关闭按钮改为鼠标悬停在整块标签区域时才显示，减少 tab 列表常驻图标噪音。
- 同步应用内、Xcode 工程、MCP CLI 与产品概览版本号。
- 新增项目 README，并引用根目录截图 `snip.png` 展示当前界面。

## [1.8.0] - 2026-06-30

### Added
- `Cmd+W` 关闭当前标签；关闭最后一个标签时随之关闭窗口；所有窗口关闭后退出 App（新增 AppDelegate 的 `applicationShouldTerminateAfterLastWindowClosed`）。原先关闭最后一个标签会自动新建一个空标签，导致无法用 `Cmd+W` 关掉窗口。

## [1.7.1-rc5] - 2026-06-30

### Changed
- 侧栏垂直方向更紧凑：标签之间间距 10→4、标签行上下内边距 6→4、各分区之间去掉额外的 4pt 顶部留白。
- 文件传输区在无传输时不再显示「使用 rz/sz 传文件…」那句固定提示，仅在有实际传输（进行中/完成/失败）时显示状态文字。

## [1.7.1-rc4] - 2026-06-30

### Fixed
- 修复在设置里改「光标样式」后屏幕上仍是块状：Metal 渲染器按 `terminal.options.cursorStyle` 画光标，而旧实现只改了 `caretView.style`（仅非 Metal 路径生效）。改为调用 `terminal.setCursorStyle(_:)`，同时更新 Metal 与非 Metal 两条路径。
- 修复在设置里改 ANSI 配色方案后不及时刷新：Metal 的 MTKView 为按需重绘（isPaused），而 SwiftTerm 的 `colorsChanged()` 只触发了 CoreText 路径、未请求 Metal 重绘，导致需等下次输出才更新。现在应用设置后统一强制刷新一次（Metal 经 `metalScaleFactorOverride` 触发重绘后落回默认，画面比例不变）。

## [1.7.1-rc3] - 2026-06-30

### Fixed
- 修复开 app 时默认第一个标签仍残留两条 PS1：首个标签的「窗口尺寸最终定型」SIGWINCH 来得较晚，rc2 会在它到来前的第一段安静里就揭幕。新增两道保险：(1) 首屏出现后至少盖住 0.45s 最小覆盖时长再揭幕；(2) 把稳定 resize（PTY setWinSize）也计入“活动”，重置安静计时，让遮罩继续盖住并在其引发的重绘安静后检测并 ^L 清屏。

## [1.7.1-rc2] - 2026-06-30

### Fixed
- 修复 rc1「每次新建标签都残留两条 PS1」的回归：rc1 会在启动输出仍在抖动时就发 ^L，与 SIGWINCH 重绘互相打架（清一条又冒一条）。改为「等输出安静（连续 0.2s 无新输出，代表启动抖动结束）后再判定」——仍重复才发一次 ^L 清屏，再等其安静并复检干净后才揭开遮罩；硬上限 3s 兜底。^L 不再与 WINCH 竞争。

## [1.7.1-rc1] - 2026-06-30

### Fixed
- 修复新建标签首屏遮罩在“迟到的重复 PS1”出现前就提前淡出、导致仍能看到两条提示符的问题：去重改为定时轮询（默认 0.1s 一次）+ 最小覆盖时长（0.5s）机制——遮罩持续盖住并轮询检测，发现重复即发 ^L 清屏（最多 3 次），只有在已过最小覆盖时长且当前画面确实干净时才淡出；硬上限 2s 兜底揭开。既能抓到出现较晚的启动重绘，又不会在重绘到来前露馅。

## [1.7.0] - 2026-06-30

### Added
- 侧栏标签标题后用稍浅颜色备注 `⌘1`～`⌘9`，提示对应的 Command+数字 快速切换快捷键（仅前 9 个标签）。

### Changed
- SSH 主机改为单击主机名整块区域即可直接连接（补 `contentShape`，原先仅文字可点）；「…」菜单移除冗余的「连接」项，仅保留编辑与删除。

## [1.6.0] - 2026-06-30

### Added
- 设置「行为」页新增光标样式选项：可选区块 / 竖线 / 下划线，并可单独开关光标闪烁；设置即时应用到所有标签（shell 通过转义序列的运行时光标切换仍生效，本设置作为默认样式）。

### Changed
- 缩短新建标签首屏遮罩时长：静默检测间隔 0.35s→0.15s，去重清屏后改为固定 0.12s 短延时淡出（不再多等一整轮静默），淡出动画 0.18s→0.12s，启动兜底窗口 1.6s→1.0s。新建标签到 PS1 显现明显更快。

## [1.5.1-rc3] - 2026-06-30

### Fixed
- 终端设置顶部的标签切换（外观/图标/格式字体/毛玻璃/行为/MCP）此前仅点中文字才生效，点击胶囊空白处无反应；为标签按钮补上 `contentShape(Rectangle())`，整块区域均可点击。

## [1.5.1-rc2] - 2026-06-30

### Fixed
- 彻底消除新建标签时“首屏 PS1 先两条再变一条”的可见闪烁：改为启动期用与终端背景同色的不透明遮罩盖住首屏，在遮罩背后完成去重/清屏重绘，待画面稳定后再淡出遮罩。用户只会看到一条干净 PS1 平滑出现，看不到中间抖动过程；用户开始输入或超过 1.6s 启动窗口时遮罩立即放行。

## [1.5.1-rc1] - 2026-06-30

### Fixed
- 重写新建标签首屏重复 PS1 的去重逻辑：由原先“启动后 0.9s 一次性检测”改为“输出停止抖动后检测、并在 4s 启动窗口内随输出反复重排”，解决慢启动/启动期 SIGWINCH 导致重复提示符晚于 0.9s 出现时漏检的问题。
- 去重判据改为与主题无关：当活动提示符（最后一条非空行）在上方出现完全相同副本时即判定重复（兼容 powerline/agnoster/p10k/纯文本），保留右侧时钟等不完全一致场景的弱判据兜底。

## [1.5.0] - 2026-06-30

### Added
- rz/sz 上传下载在侧栏显示传输进度；可解析本机 `rz`/`sz` 的进度输出并展示文件名与百分比，缺少百分比时使用不确定进度条。
- 下载流程改为先选择本机保存文件，再输入远端路径；接收完成后会把临时目录中的文件移动到用户选择的位置。

## [1.4.0] - 2026-06-30

### Added
- 侧栏新增 rz/sz 文件传输入口，可选择本机文件上传到当前终端远端，或输入远端文件路径下载到本机目录。
- 文件传输会先检查远端 `rz`/`sz` 是否可用；若远端缺少 `lrzsz`，会在终端输出 Debian/Ubuntu、Fedora/RHEL/CentOS、Arch、Alpine 和 macOS 的安装命令。
- 本机传输通过本地 `sz`/`rz` 与当前 PTY 数据流桥接，缺少本机 `lrzsz` 时提示使用 Homebrew 安装。

### Fixed
- 启动期检测 powerlevel10k/SwiftTerm 重复绘制的首屏 PS1，并在用户输入前触发一次 zsh 清屏重绘，避免默认标签顶部堆出多条提示符。

## [1.3.1-rc2] - 2026-06-30

### Fixed
- 将侧栏加号恢复为单击立即新建本地标签，避免先弹出“新建标签”菜单造成多余点击。
- 接管 SwiftTerm resize delegate 并防抖启动/PTY resize，避免启动首屏 PS1 被多次重绘。
- 在 MuseTerm 启动的 shell 环境中关闭 powerlevel10k instant prompt，避免预提示符残留成重复 PS1。
- 为 MuseTerm shell 使用专用持久 `XDG_CACHE_HOME`，并在启动前清理 p10k instant prompt 缓存。

## [1.3.1-rc1] - 2026-06-30

### Fixed
- 使用 AppKit 原生隐藏 inactive 终端视图，避免多个 SwiftTerm/Metal 标签视图叠绘造成 PS1 重影。

## [1.3.0] - 2026-06-30

### Added
- 侧栏新增终端录制捷径，可录制当前标签输入、按原延迟回放、改名、删除，并通过 JSON 编辑录制内容。
- 录制过程识别不回显输入，敏感字节仅写入 macOS Keychain，录制 JSON 只保存引用。
- 新增 SSH 主机管理，可保存本地 SSH profile，并支持多跳跳转机、每一跳独立端口和独立密钥文件。
- SSH 标签通过生成 OpenSSH config 启动，支持额外 SSH 选项和连接后启动命令。

### Changed
- 新建连接入口改为菜单，可直接打开本地 shell 或已保存的 SSH 主机。

## [1.2.0-rc31] - 2026-06-30

### Fixed
- 延后终端 shell 启动到视图进入窗口并完成布局后，避免首屏 PS1 被重复绘制。
- 修复终端快捷指令编译语法，保证当前 Xcode 工具链可正常构建。

## [1.2.0-rc30] - 2026-06-30

### Fixed
- 将终端设置页的原生 TabView 替换为自绘 tab 切换条，避免键盘 focus ring 产生突兀边框。

## [1.2.0-rc29] - 2026-06-30

### Changed
- 将企鹅图标设为默认 App Logo，并同步设置页默认图标文案。

## [1.2.0-rc28] - 2026-06-30

### Fixed
- 终端右侧同步使用同色边距，保持左右留白一致且不露出外层 panel 底色。

## [1.2.0-rc27] - 2026-06-30

### Fixed
- 为终端左侧文字间距补同色背景，保留左侧留白且不再露出外层 panel 底色。

## [1.2.0-rc26] - 2026-06-30

### Fixed
- 让终端内容区延伸到窗口顶部，避免隐藏标题栏区域露出系统灰色背景。

## [1.2.0-rc25] - 2026-06-30

### Fixed
- 移除终端视图手动左侧 inset，避免侧栏旁出现偏宽的灰色竖带。

## [1.2.0-rc24] - 2026-06-30

### Fixed
- 移除新终端会话启动时自动输出的欢迎语，减少终端首屏占用。

## [1.2.0-rc23] - 2026-06-30

### Fixed
- 移除侧栏和终端内容区之间的分隔竖线，并调整启动欢迎语换行方式，避免触发 zsh 反白 `%` 的部分行提示。

## [1.2.0-rc22] - 2026-06-30

### Added
- 侧栏新增图标按钮，可折叠或展开标签列表；设置的“行为”分组同步增加标签列表显示开关。

## [1.2.0-rc21] - 2026-06-30

### Fixed
- 修复默认 AppIcon 和动物头像图标带白色画布背景的问题，改为透明外沿以适配 Dock 显示。

## [1.2.0-rc20] - 2026-06-30

### Fixed
- 修复侧栏标签标题判断本机 `user@host` 时在主线程调用 `NSHost` 阻塞解析，导致设置变更和 UI 重绘明显卡顿的问题。

## [1.2.0-rc19] - 2026-06-30

### Added
- 新增本机 CLI/MCP 工具桥，发布当前标签、最新屏幕和历史文本，并支持向指定标签发送文本或控制键。
- 设置新增“MCP 与工具”分组，可安装 `museterm` CLI，并展示 CLI/MCP 使用示例。

## [1.2.0-rc18] - 2026-06-30

### Added
- 新增 Q 版默认 AppIcon，并在设置中加入 App 图标切换，可在默认图标和多款动物头像图标之间切换。

## [1.2.0-rc17] - 2026-06-30

### Fixed
- 将 macOS 发布最低系统版本降至 13.0，并为设置窗口激活逻辑增加 macOS 13 兼容回退，确保发布产物可覆盖 macOS 13.7。

## [1.2.0-rc16] - 2026-06-30

### Fixed
- 修复 ANSI 配色转换函数在 Xcode 默认 MainActor 隔离下产生的构建警告。

### Changed
- 忽略本地 Xcode DerivedData 与用户态缓存文件，避免构建产物进入版本库。

## [1.2.0-rc15] - 2026-06-30

### Added
- 新增终端 ANSI 字符配色方案，可在 Apple、Tango、Solarized、Dracula、One Dark、Nord 等经典 palette 中切换。

### Changed
- 为终端内容区左侧恢复约半个等宽字符的轻量 padding，避免文字贴边，同时保留终端背景贴合皮肤。

## [1.2.0-rc14] - 2026-06-30

### Fixed
- 将菜单快捷键与窗口级键盘桥接统一按 `NSEvent.timestamp` 去重，确保同一次 `Cmd+T` 不会双建，同时保留 SwiftTerm first responder 下的快捷键可靠性。

## [1.2.0-rc13] - 2026-06-30

### Fixed
- 修复 `Cmd+T` 同时走菜单快捷键和窗口级键盘桥接导致一次按键仍可能创建两个标签的问题。
- 去掉终端区域外层 padding、阴影和内部 inset，避免皮肤背景与终端背景之间出现粗灰边框。
- 将备用 shell 补位延后到新建标签后的空闲窗口，降低补热备时阻塞主线程带来的新建标签卡顿体感。

## [1.2.0-rc12] - 2026-06-30

### Fixed
- 保留菜单快捷键显示和系统快捷键通道，同时为新建标签快捷键增加短时间去重，避免窗口桥接与菜单命令双触发。

## [1.2.0-rc11] - 2026-06-30

### Fixed
- 修复标签快捷键同时被菜单命令和窗口级键盘桥接处理，导致一次 `Cmd+T` 可能新建两个标签并拖慢热备补位的问题。

## [1.2.0-rc10] - 2026-06-30

### Fixed
- 修复主机名归一化工具函数在 Xcode 默认 MainActor 隔离下产生的构建警告。

## [1.2.0-rc9] - 2026-06-30

### Fixed
- 进一步降低新建标签等待：下一标签预热时同时启动备用 shell，点击新建时直接接入已就绪的终端会话。

## [1.2.0-rc8] - 2026-06-30

### Fixed
- 优化新建标签速度：预热下一份 SwiftTerm 控制器，并缓存终端偏好应用结果，避免每次 SwiftUI 更新都重复配置字体、颜色和 Metal 渲染器。

## [1.2.0-rc7] - 2026-06-30

### Fixed
- 将标签快捷键改为窗口级键盘事件处理，避免 SwiftTerm 的 AppKit first responder 使 `Cmd+T` 等快捷键无法触达当前标签工作区。

## [1.2.0-rc6] - 2026-06-30

### Added
- 新增标签快捷键：`Cmd+T` 新建标签、`Cmd+Shift+[` / `Cmd+Shift+]` 切换前后标签、`Cmd+1` 到 `Cmd+9` 直达指定标签。

## [1.2.0-rc5] - 2026-06-30

### Fixed
- 加固标签切换时的终端渲染保活逻辑，不再隐藏 SwiftTerm 内部视图，避免切回已有内容的标签后终端区域变空白。

## [1.2.0-rc4] - 2026-06-30

### Fixed
- 修复切换多个标签后 SwiftTerm 视图被拆卸重挂，导致原本有内容的终端区域变空白的问题。

## [1.2.0-rc3] - 2026-06-30

### Changed
- 调整浅色皮肤的终端文字区底色，让终端背景更贴近当前皮肤而不是接近纯白。
- 压缩左侧标签行高度，本机标签优先显示当前目录，远端标签保留 `user@host`。
- 去掉侧栏设置图标背后的独立填充色，让底部入口融入侧栏背景。

## [1.2.0-rc2] - 2026-06-30

### Changed
- 将侧栏底部设置入口压缩为单个图标按钮，减少底部占用并让侧栏更紧凑。

### Fixed
- 修复默认初始化标签可能过早创建终端控制器，导致首个标签没有进入 shell 的问题。
- 修复 `Cmd+,` 依赖系统设置 selector 不稳定，无法唤起设置窗口的问题。

## [1.2.0-rc1] - 2026-06-30

### Added
- 新增 macOS 标准设置窗口入口，支持通过 `Cmd+,` 唤起设置。

### Changed
- 将设置窗口拆分为外观、字体、毛玻璃和行为分组，降低窗口高度并改善浏览效率。

## [1.1.1-rc1] - 2026-06-30

### Fixed
- 修复 SwiftTerm 终端视图未主动获取键盘焦点，导致终端无法输入文字的问题。

## [1.1.0] - 2026-06-30

### Added
- 集成 SwiftTerm，新增可运行本地 shell 的多标签终端主界面。
- 新增左侧标签栏、标签标题同步、当前目录显示和退出状态显示。
- 新增从 MuseMail 迁移并适配终端场景的皮肤配色系统，默认使用海盐晨蓝。
- 新增终端设置面板，支持毛玻璃材质、玻璃强度、终端透明度、染色、柔光、字号、行高、主字体和回退字体配置。
- 新增中英文基础本地化资源。

### Changed
- 将默认 SwiftData 示例应用替换为 MuseTerm 终端应用。

## [1.0.0] - 2026-06-30

### Added
- 初始化 macOS SwiftUI 应用工程。
