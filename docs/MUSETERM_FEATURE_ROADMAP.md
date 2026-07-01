# MuseTerm Feature Roadmap

> 最后更新：2026-07-01
> 当前版本基线：v1.144.0
> 文档状态：概念规划、可行性评估与落地状态跟踪。

## 目标

MuseTerm 已具备多标签终端、SSH profile、终端录制、rz/sz 文件传输、CLI/MCP 工具桥、皮肤与设置系统。下一阶段不宜先追求“大而全”，而应优先做能放大现有能力、形成产品辨识度的功能。

核心方向：

- 把终端从纯滚屏文本升级为可检索、可复用、可解释的工作记忆。
- 保持终端原生体验，不阻断用户敲命令。
- 对危险操作、生产环境、敏感输出提供可见但克制的安全护栏。
- 让 AI 能读上下文、解释失败、生成建议，但关键执行仍由用户确认。

## 优先级总览

| 优先级 | 功能 | 推荐阶段 | 可行性 | 核心价值 |
| --- | --- | --- | --- | --- |
| P0 | 结构化命令块与执行摘要 | v1 | 高 | 让命令、输出、退出码、耗时可管理 |
| P0 | 历史与输出搜索 | v1 | 高 | 解决“我上次那个报错在哪”的高频痛点 |
| P1 | 项目工作区恢复 | v2 | 中高 | 一键恢复项目上下文、标签和 SSH |
| P1 | 安全模式与高危命令预警 | v2 | 中 | 避免生产环境误操作，增强信任感 |
| P1 | AI Explain / MCP 解释面板 | v2 | 中 | 利用已有 CLI/MCP 桥形成差异化 |
| P2 | 任务、端口与本地服务面板 | v3 | 中 | 面向开发工作流的控制台能力 |
| P2 | Runbook 导出与命令回放 | v3 | 中 | 把一次操作沉淀成文档和自动化 |
| P3 | 成就、统计与轻娱乐系统 | v4 | 高 | 增加记忆点，但不能干扰主流程 |

## 当前落地状态

v1.144.0 已完成一百四十一条纵向切片：

- 连续失败最近间隔趋势：`RepeatedFailureDiagnostic` 会输出 `latestIntervalTrend`，基于最近失败间隔与平均失败间隔判断重试节奏正在 `accelerating`、`steady` 还是 `slowing`，方便 AI/MCP 和 Runbook 判断是否该先停下来排查。

v1.143.0 已完成一百四十条纵向切片：

- 连续失败最近间隔：`RepeatedFailureDiagnostic` 会输出 `latestIntervalMilliseconds`，记录最近两次连续失败之间的间隔，让 AI/MCP 和 Runbook 能区分整段平均节奏与用户刚刚是否又快速重试。

v1.142.0 已完成一百三十九条纵向切片：

- 连续失败节奏分类：`RepeatedFailureDiagnostic` 会输出 `cadence`，用 `immediate_retry`、`rapid_retry` 或 `spaced_retry` 概括平均失败间隔，让 AI/MCP 和 Runbook 不必自行推断重复失败是否属于密集重试。

v1.141.0 已完成一百三十八条纵向切片：

- 连续失败平均间隔：`RepeatedFailureDiagnostic` 会输出 `averageIntervalMilliseconds`，基于连续失败时间窗和次数计算平均失败间隔，让 AI/MCP 和 Runbook 能判断失败是否来自短时间密集重试。

v1.140.0 已完成一百三十七条纵向切片：

- 连续失败上下文稳定性：`RepeatedFailureDiagnostic` 会输出 `contextStability`，用单一稳定枚举汇总连续失败窗口是完全稳定、命令变化、工作目录变化，还是命令与工作目录都变化，方便 AI/MCP 和 Runbook 快速分流。

v1.139.0 已完成一百三十六条纵向切片：

- 连续失败上下文变化原因：`RepeatedFailureDiagnostic` 会输出 `contextChangeReasons`，用稳定 reason code 标明连续失败窗口内是命令变化、工作目录变化，还是两者都变化，方便 AI/MCP 和 Runbook 解释 `contextChanged`。

v1.138.0 已完成一百三十五条纵向切片：

- 连续失败上下文变化信号：`RepeatedFailureDiagnostic` 会记录窗口内全部命令块 ID、唯一命令、唯一工作目录和 `contextChanged`，让 AI/MCP、CLI 与 Runbook 能判断连续失败期间是否已经换过命令或工作目录。

v1.137.0 已完成一百三十四条纵向切片：

- 连续失败窗口命令文本：`RepeatedFailureDiagnostic` 会记录连续同类失败窗口内首次与最近失败命令文本，并同步给 AI 上下文、MCP/CLI 快照和 Runbook 导出；命令文本沿用敏感信息脱敏策略，让复盘不用只靠命令块 ID 反查。

v1.136.0 已完成一百三十三条纵向切片：

- 连续失败窗口证据行：`RepeatedFailureDiagnostic` 会记录连续同类失败窗口内首次与最近失败命令的 `outputTail` 行号和证据文本，并同步给 AI 上下文、MCP/CLI 快照和 Runbook 导出，让复盘可以直接定位窗口两端的原始输出。

v1.135.0 已完成一百三十二条纵向切片：

- 连续失败窗口引用：`RepeatedFailureDiagnostic` 会记录连续同类失败窗口内首次与最近失败命令块 ID 及其工作目录，并同步给 AI 上下文、MCP/CLI 快照和 Runbook 导出，让外部工具可以从摘要稳定回跳到原始命令块。

v1.134.0 已完成一百三十一条纵向切片：

- 失败诊断工作目录：`CommandBlockDiagnostics` 会记录最近失败命令和最近失败诊断对应的工作目录，并同步给 AI 上下文、MCP/CLI 快照、Runbook 导出和建议动作证据锚点，让外部工具判断失败时能直接绑定项目目录。
- 失败诊断命令块引用：`CommandBlockDiagnostics` 会记录最近失败命令 ID 和最近失败诊断对应的命令块 ID，并同步给 AI 上下文、MCP/CLI 快照、Runbook 导出和建议动作证据锚点，让外部工具能从诊断稳定跳回原始结构化命令块。
- 失败诊断证据行：`CommandBlockDiagnostics` 会记录最近失败诊断在命令 `outputTail` 中的行号与证据文本，并同步给 AI 上下文、MCP/CLI 快照、Runbook 导出和建议动作证据锚点，让“失败原因从哪一行来”可以被外部工具和复盘文档稳定消费。
- 无效 Web URL 选区降噪：带 `http://` 或 `https://` 但端口无效的选区不再落入路径或 `rg` 搜索兜底，避免 `http://localhost:70000` 这类文本误弹路径菜单；有效 URL 仍保留 URL/端口上下文。

v1.130.0 已完成一百二十七条纵向切片：

- 文件行号选区降噪：右键菜单会把 `Foo.swift:42`、`users_controller.rb:12:8` 等常见源码/配置文件行号从 host:port 识别中排除，避免误弹 URL/端口动作；真实 `example.com:8080` 与 `localhost:3000` 仍保留端口上下文。

v1.129.0 已完成一百二十六条纵向切片：

- 选区搜索动作降噪：右键菜单的 `rg` 填入动作只面向普通短单行文本，URL、明确端口、PID、Git hash、JSON 和过长单行选区会交给各自上下文动作，减少菜单重复项。

v1.128.0 已完成一百二十五条纵向切片：

- 选区本机路径还原：右键路径菜单会静态还原简单单引号和反斜杠转义路径，让已存在的 `'path with space'` 与 `path\ with\ space` 选区也能获得 Finder 显示和 `cd` 动作；ANSI-C `$'...'` 仍不做 shell eval，继续保守跳过。

v1.127.0 已完成一百二十四条纵向切片：

- 选区 Base64 转换降噪：右键菜单只有在选区满足可信 Base64 形态、合法 padding 且解码结果是可打印 UTF-8 时才展示解码动作，避免普通短文本和日志片段误触转换入口。

v1.126.0 已完成一百二十三条纵向切片：

- 选区端口识别降噪：裸数字优先作为 PID 处理，只有 `:3000`、`localhost:3000` 或带有效端口的 URL 才展示端口动作，避免同一数字选区同时弹出端口和 PID 排查入口。

v1.125.0 已完成一百二十二条纵向切片：

- 选区路径识别降噪：右键菜单不再因为普通短句、语义化版本号或纯描述文本包含空格就展示路径动作；明确路径、已存在本机路径、shell 转义路径和文件名式选区仍保留路径子菜单。

v1.124.0 已完成一百二十一条纵向切片：

- 路径删除动作交互化：右键路径删除动作改为填入 `rm -i --`，让 shell 在真正删除前再确认一次；MuseTerm 仍只填入命令，不自动回车。

v1.123.0 已完成一百二十条纵向切片：

- 路径选区本机动作：右键路径子菜单支持在 Finder 中显示本机路径，并可填入 `rm -i --` 删除命令；删除动作仍只进入终端输入区，不自动回车执行。

v1.122.0 已完成一百一十九条纵向切片：

- 工具读取 payload 版本来源：CLI/MCP 的屏幕、历史和命令块读取 payload 顶层同步暴露 `app` 与 `version`，外部工具无需先调用 `list_tabs` 即可判断读取结果来自哪版 MuseTerm。
- 终端选区上下文动作：右键菜单会根据选区识别 URL、路径、端口、PID、Git hash、JSON 和常见编码，并提供脱敏复制、Markdown、AI 提示词、只填入不自动执行的排查命令等动作，让输出片段更容易转成安全的下一步。

v1.121.1-rc1 修复：终端右键菜单中“转义键入所选路径”保持可点击，点击时再读取选区并在无可用选区时给出系统反馈，避免因菜单打开时选区读取时机不稳定导致功能被置灰。

v1.121.0 已完成一百一十七条纵向切片：

- AI Provider 设置：已支持常见 Provider 与自定义端点，API Key 保存到本机 Keychain。
- 结构化命令块基础采集：已记录用户提交命令、工作目录、时间、输出尾部、输出字符数和中断/进程退出状态。
- 命令块完成来源：已记录命令结束来源，区分 shell integration 真实退出码、进程退出兜底、用户中断、被下一条命令覆盖和未知来源，并同步给搜索、AI 上下文与 CLI/MCP 快照。
- 命令块开始来源：本地 zsh/fish 与远端 zsh 已通过 shell marker 回传命令开始和命令文本，命令块会记录开始来源；bash 仍保守使用用户输入推断开始、shell hook 回传结束码。
- 会话 shell 名探测：本地会话会记录登录 shell 名；SSH 启动时先发送轻量 shell 探测 marker，回传 `$SHELL` 后归一化为 `zsh` / `bash` / `fish` 等稳定 shell 名，为后续远端 fish 与 nested shell 降级判断打基础。
- 标签 shell 标识：侧栏标签行会在目录/远端摘要前显示轻量 shell badge，帮助区分 zsh、bash、fish 等会话；侧栏顶部工具按钮分到第二行，避免标题与按钮在窄宽度下互相挤压。
- 工具快照 shell 环境：CLI/MCP 标签快照会暴露 `shellName`，让外部 AI 工具读取标签列表时即可知道当前会话是 zsh、bash、fish 还是未知 shell，减少解释命令和生成建议时的环境猜测。
- 工具读取 payload 执行环境：CLI/MCP 的屏幕、历史和命令读取 payload 顶层同步暴露 `shellName` 与 `currentDirectory`，外部工具无需先调用 `list_tabs` 也能按当前 shell 和工作目录解释输出与命令块。
- 工具读取 payload 选择态：CLI/MCP 的屏幕和历史读取 payload 顶层同步暴露 `selectedTabID`，外部工具可判断返回内容来自当前选中标签还是指定的其他标签。
- 本机端口识别：任务与端口面板会为监听端口补充常见服务名和进程工作目录，端口搜索可按 PID、命令、协议、地址、端口、服务名和工作目录多词匹配，让“谁占用了这个端口”更接近可读诊断而不是裸 `lsof` 输出。
- 本机端口扫描器拆分与中文转义还原：本机监听端口扫描、`lsof` 字段解析、服务名识别和搜索匹配模型已拆分到 `LocalServiceScanner.swift`；`lsof` 返回的 `\xNN` / 八进制字节转义会按 UTF-8 还原，中文进程名和中文工作目录可正常展示与搜索。
- 命令块输出摘要：已把输出洞察沉入结构化命令块，记录洞察类型、首个错误/警告、URL、文件路径、commit hash 和堆栈线索，并同步给搜索、AI 上下文与 CLI/MCP 快照。
- Runbook 输出摘要：导出的 Markdown 会消费命令块里的紧凑输出摘要，把关键错误、URL、路径、commit 与堆栈线索写成独立段落，并沿用现有敏感信息脱敏开关。
- 失败诊断展示：命令搜索卡片已优先使用结构化输出摘要展示洞察标签；失败命令会直接露出首条关键诊断行，让错误原因不必埋在输出尾部里。
- 最近失败统计：任务与端口面板的本次会话统计已展示最近失败诊断行，并在统计模型层统一脱敏，让“失败了几次”进一步变成“最近卡在哪”。
- 连续失败提醒：统计面板会在最近连续 3 次以上同一诊断失败时显示重复提醒；最新命令成功或诊断变化时不提示，保持克制。
- 诊断摘要复用：Runbook 导出与 AI Explain 当前过滤上下文会复用同一套 `CommandBlockDiagnostics`，记录最近失败和连续同类失败摘要，并沿用脱敏策略。
- CLI/MCP 诊断摘要：工具状态文件为每个 tab 增加 `commandDiagnostics`，`museterm commands` 与 MCP `read_commands` 返回 `diagnostics` + `commands`，外部工具可直接读取最近失败和连续同类失败线索。
- 诊断动作契约拆分：`CommandDiagnosticAction` 及其稳定 action code 枚举已从 `TaskPortPanel.swift` 拆分到独立 `CommandDiagnosticAction.swift`，让结构化建议排查动作可以继续深化而不拖大面板实现文件。
- 工具快照序列号：工具状态快照新增单调递增的 `snapshotSequence`，并透传到 CLI/MCP 元数据响应，外部工具轮询时可判断是否读到新快照，不必只比较时间字符串。
- 工具请求响应元数据：输入/按键请求 response 文件会返回 `schemaVersion`、App 名称、版本、`snapshotSequence`、`action` 和成功目标 `tabID`，让外部工具能定位请求由哪版 App、哪次快照附近处理。
- CLI 输入响应 JSON 输出：`museterm input --json` 与 `museterm key --json` 会输出完整工具 response 元数据，默认短消息输出保持兼容，便于脚本直接消费请求处理结果。
- CLI 请求等待时间：`museterm input` 与 `museterm key` 支持 `--timeout SECONDS`，脚本可按场景调整等待 App response 文件的时长，超时时间必须为正数。
- MCP 写入响应元数据：MCP `send_text` 与 `send_key` 支持 `timeout` 和 `metadata` 参数，默认返回短消息，`metadata: true` 时返回完整工具 response 元数据。
- CLI/MCP 命令列表顶层元数据：`museterm commands` 与 MCP `read_commands` 会返回 `tabID`、`selectedTabID`、`commandCount`、`returnedCommandCount` 和 `outputTailLimit`，外部工具读取命令块时无需自行推断标签来源、命令总量和 tail 截断参数。
- MCP 标签列表元数据：MCP `list_tabs` 默认保持数组输出兼容，传入 `metadata: true` 时返回 `schemaVersion`、App 名称、版本、选中标签 ID 和标签数组，让外部工具读取标签列表时也能稳定判断契约版本。
- CLI/MCP 契约版本：工具状态快照顶层、命令诊断快照、`museterm tabs`、`museterm commands` 和 MCP `read_commands` 均暴露 `schemaVersion`，让外部工具可按 JSON 契约版本做兼容判断。
- CLI/MCP 屏幕与历史截断元数据：`museterm screen --json`、`museterm history --json` 和 MCP `read_screen` / `read_history` 的 `metadata: true` 会返回文本、字符数、返回字符数、截断上限和截断状态，同时保留默认纯文本输出兼容性。
- MCP 屏幕元数据端到端验证：测试会启动生成的 Ruby MCP 脚本，发送真实 JSON-RPC `tools/call read_screen` 请求，并验证 `metadata: true` 返回的截断元数据。
- CLI/MCP 输出截断元数据：`museterm commands --chars N` 和 MCP `read_commands` 会为每个命令块标注 `outputTailCharacters`、`outputTailReturnedCharacters`、数字或 `null` 类型的 `outputTailLimit`、`outputTailTruncated` 与 `outputTailStoredTruncated`，并用真实 Ruby CLI 端到端测试覆盖，避免外部工具把 App 内部 tail 或二次截断 tail 当成完整输出。
- 诊断摘要可操作化：`CommandBlockDiagnostics` 新增失败命令数、最近失败命令和建议下一步查看项，并同步进入 Runbook、AI 当前过滤上下文与 CLI/MCP `diagnostics`。
- 最近失败退出码：`CommandBlockDiagnostics` 新增 `latestFailedExitCode`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 可直接消费最近失败命令退出码。
- 最近失败耗时：`CommandBlockDiagnostics` 新增 `latestFailedDurationMilliseconds`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 可直接消费最近失败命令耗时，区分快速失败、慢失败和疑似超时。
- 最近失败命令来源：`CommandBlockDiagnostics` 新增 `latestFailedCommandStartSource`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 可直接消费最近失败命令开始来源，用于判断命令文本和边界来自 shell integration 还是用户输入推断。
- 最近失败完成来源：`CommandBlockDiagnostics` 新增 `latestFailedCompletionSource`，Runbook、AI 上下文和 CLI/MCP `commandDiagnostics` 可直接消费最近失败命令完成来源，用于判断退出码来自 shell integration、进程退出兜底、用户中断还是覆盖结束。
- 诊断严重级别：`CommandBlockDiagnostics` 新增 `diagnosticSeverity`，将 none/failed/repeated/critical 暴露到 Runbook、AI 上下文和 CLI/MCP `diagnostics`，帮助外部工具先判断排查优先级。
- 诊断优先级分数：`CommandBlockDiagnostics` 新增 `diagnosticPriorityScore`，按失败严重级别、诊断分类、分类可信度和连续失败次数生成 0-100 稳定分数，并同步给 AI 上下文与 CLI/MCP `diagnostics`，方便外部工具排序排查入口。
- 诊断优先级因素：`CommandBlockDiagnostics` 新增 `diagnosticPriorityFactors`，用稳定 reason code 解释优先级分数来源，并同步给 Runbook、AI 上下文与 CLI/MCP `diagnostics`，让外部工具能解释和筛选高优先级失败。
- 诊断分类：`CommandBlockDiagnostics` 新增 `diagnosticCategory`，把最近失败归类为端口占用、权限、缺文件、命令缺失、Git、连续失败或通用问题，并同步给 Runbook、AI 上下文和 CLI/MCP `diagnostics`，让建议命令和外部工具复用同一套判断。
- 诊断分类依据：`CommandBlockDiagnostics` 新增 `diagnosticCategoryEvidence`，记录分类命中的脱敏证据文本，并同步给 Runbook、AI 上下文和 CLI/MCP `diagnostics`，让外部工具知道分类从哪一行命令或错误得出。
- 诊断分类可信度：`CommandBlockDiagnostics` 新增 `diagnosticCategoryConfidence`，用 `high` / `medium` / `low` 区分明确错误命中、上下文推断和保守兜底，并同步给 Runbook、AI 上下文和 CLI/MCP `diagnostics`。
- 结构化建议排查动作：`CommandBlockDiagnostics` 新增 `suggestedNextAction`，把建议排查步骤拆成标题、原因、命令、安全级别和确认要求，并同步给 Runbook、AI 上下文和 CLI/MCP `diagnostics`；旧的 `suggestedNextCommand` 保留以兼容现有调用方。
- 建议排查动作 ID：`suggestedNextAction` 新增稳定 `id`，例如 `inspect_git_state`、`inspect_repeat_context`，Runbook、AI 上下文和 CLI/MCP 可按动作类型消费，不必依赖可变标题文案。
- 建议排查动作自解释：`suggestedNextAction` 新增 `sourceCategory` 与 `confidence`，单个 action 对象即可说明建议来自哪类诊断以及可信度，减少 MCP/AI 工具拼接旁路字段的成本。
- 建议排查动作优先级：`suggestedNextAction` 新增 `priorityScore` 与 `priorityFactors`，让 action 对象自身也能排序并解释优先级来源，不必依赖父级 diagnostics 字段。
- 建议排查动作证据锚点：`suggestedNextAction` 新增 `evidenceAnchors`，用稳定 code 标明建议动作锚定了哪些诊断来源，让 AI/MCP 工具能解释建议从哪里来，同时避免重复携带敏感日志内容。
- 建议排查动作作用域：`suggestedNextAction` 新增 `actionScope`，用稳定 code 标明建议动作主要检查本地网络、权限边界、shell 环境、工作目录、Git 仓库、连续失败上下文或当前会话，帮助外部工具区分“在哪里执行”和“在排查什么”。
- 建议排查动作预期结果类型：`suggestedNextAction` 新增 `expectedResultKind`，用稳定 code 标明建议命令预期返回监听端口列表、身份与权限信息、PATH、目录列表、Git 状态或上下文快照，让 AI/MCP 工具更容易按输出形态解释后续结果。
- 建议排查动作预期结果字段：`suggestedNextAction` 新增 `expectedResultFields`，用稳定 code 标明建议命令输出里应重点抽取端口、PID、进程名、当前用户、目录权限、PATH 条目、Git 分支、upstream 和 dirty 状态等字段。
- 建议排查动作预期结果信号：`suggestedNextAction` 新增 `expectedResultSignals`，用稳定 code 标明建议命令输出中哪些信号代表只读检查已经拿到可用证据，便于 AI/MCP 判断是否足够进入下一步。
- 建议排查动作结果解析提示：`suggestedNextAction` 新增 `resultParsingHints`，用稳定 code 描述建议命令输出应如何解析，例如按行文本、空白分隔列、PATH 列表、组合命令输出、目录列表、Git porcelain 状态或可选 Git 输出。
- 建议排查动作结果解释提示：`suggestedNextAction` 新增 `resultInterpretationHints`，用稳定 code 描述建议命令输出应如何解释，例如空端口列表表示本机无监听者、权限输出需要比较用户与权限位、Git dirty 状态需要用户决策。
- 建议排查动作结果决策提示：`suggestedNextAction` 新增 `resultDecisionHints`，用稳定 code 描述建议命令结果应触发的保守决策分支，例如端口 owner 需要用户决定、权限不匹配需要明确提权、Git dirty 状态需要先处理工作树。
- 建议排查动作结果局限提示：`suggestedNextAction` 新增 `resultCaveats`，用稳定 code 描述建议命令结果的适用局限，例如本机端口扫描只覆盖当前网络命名空间、PATH 只代表当前 shell、Git status 需要位于仓库内。
- 建议排查动作敏感结果字段：`suggestedNextAction` 新增 `sensitiveResultFields`，用稳定 code 标明建议命令结果中哪些字段可能携带路径、用户、进程、Git 或目录元数据等敏感上下文，便于外部工具优先脱敏。
- 建议排查动作结果脱敏提示：`suggestedNextAction` 新增 `resultRedactionHints`，用稳定 code 提示建议命令结果中应优先脱敏的内容类型，例如路径、用户、进程、监听地址、Git 分支和 upstream。
- 建议排查动作结果刷新触发条件：`suggestedNextAction` 新增 `resultRefreshTriggers`，用稳定 code 声明哪些上下文变化会让建议命令结果过期，例如进程、监听端口、工作目录、权限、PATH、文件系统或 Git 状态变化。
- 建议排查动作结果隐私级别：`suggestedNextAction` 新增 `resultPrivacyLevel`，用稳定 code 汇总建议命令结果的隐私敏感级别，帮助 AI/MCP 工具在解释、转发或记录前选择本地处理或脱敏策略。
- 建议排查动作结果分享策略：`suggestedNextAction` 新增 `resultSharingPolicy`，用稳定 code 声明建议命令结果应直接分享、先脱敏再分享，还是仅本地查看，让 AI/MCP 工具在转发诊断结果前能遵守更明确的隐私边界。
- 建议排查动作结果保留策略：`suggestedNextAction` 新增 `resultRetentionPolicy`，用稳定 code 声明建议命令结果可完整保存、只能保存脱敏摘要，还是仅保留在本机会话，帮助外部工具在记录日志或建立索引前遵守更细的隐私边界。
- 建议排查动作执行模式：`suggestedNextAction` 新增 `executionMode`，当前统一为 `stage_only`，明确外部工具只能填入或展示建议动作，执行仍必须由用户确认。
- 建议排查动作执行目标：`suggestedNextAction` 新增 `executionTarget`，用稳定 code 声明建议命令应在当前终端会话、工作目录、shell 环境、Git 仓库或网络命名空间中理解，减少本地/远端/容器/错误目录误用。
- 建议排查动作结果适用范围：`suggestedNextAction` 新增 `resultValidityScope`，用稳定 code 声明建议命令结果可在哪个范围内复用，例如当前终端会话、网络命名空间、工作目录、Shell 环境或 Git 仓库。
- 建议排查动作结果新鲜度策略：`suggestedNextAction` 新增 `resultFreshnessPolicy`，用稳定 code 声明建议命令结果是实时快照、上下文绑定，还是仅对当前失败尝试有效，帮助外部工具判断历史诊断结果能否复用。
- 建议排查动作结果复用键字段：`suggestedNextAction` 新增 `resultReuseKeyFields`，用稳定 code 声明复用建议命令结果前应比较哪些上下文，例如终端会话、工作目录、Shell 环境、Git 仓库、监听端口、权限元数据或失败指纹。
- 建议排查动作结果复用策略：`suggestedNextAction` 新增 `resultReusePolicy`，用稳定 code 明确历史建议命令结果应先刷新再用、仅在复用键匹配时可用，还是不能跨失败尝试复用。
- 建议排查动作结果复用验证检查：`suggestedNextAction` 新增 `resultReuseValidationChecks`，用稳定 code 描述复用历史建议命令结果前应完成的机器可读检查，例如刷新动态快照、匹配工作目录、Shell 环境、用户身份、Git 状态或失败指纹。
- 建议排查动作重试条件：`suggestedNextAction` 新增 `retryCondition`，用稳定 code 描述用户考虑重跑失败命令前应满足的条件，让排查动作和后续重跑边界更容易被工具串起来。
- 建议排查动作执行前检查：`suggestedNextAction` 新增 `preflightChecks`，用结构化清单描述填入建议动作前应确认的上下文，避免在目录、权限、Git 状态或失败输出仍不清楚时盲目重试。
- 建议排查动作自动化护栏：`suggestedNextAction` 新增 `automationGuardrails`，明确建议动作不能自动越过的边界，例如不自动 kill 进程、不自动 sudo/chmod、不自动安装依赖、不自动执行 Git 破坏性操作。
- 建议排查动作用户决策点：`suggestedNextAction` 新增 `userDecisionPoints`，明确哪些判断必须交给用户拍板，例如是否停进程、提权、安装依赖、恢复文件、处理 Git 状态或继续重试。
- 建议排查动作完成判据：`suggestedNextAction` 新增 `completionCriteria`，明确这一轮排查何时可以收口，避免工具无限追加建议或在证据不足时进入下一步。
- 建议排查动作观察信号：`suggestedNextAction` 新增 `expectedSignals`，描述执行只读排查命令后应该重点观察什么，让 Runbook 和 AI 上下文更容易转成复盘步骤。
- 建议排查动作降级步骤：`suggestedNextAction` 新增 `fallbackNextSteps`，描述观察不到预期信号时下一步应该怎样保守排查，并同步给 Runbook、AI 上下文和 CLI/MCP `diagnostics`。
- 诊断指纹归一化：最近失败诊断会生成脱敏后的 `recentFailureFingerprint`，连续同类失败改用归一化指纹比较，避免行号、路径、URL、hash 或重试次数变化导致同类失败被拆散。
- 连续失败时间窗：`RepeatedFailureDiagnostic` 新增 `firstOccurredAt` 与 `latestOccurredAt`，Runbook、AI 上下文和 CLI/MCP `diagnostics` 能直接看到这波同类失败从何时开始、最新一次发生在何时。
- 连续失败持续时长：`RepeatedFailureDiagnostic` 新增 `durationMilliseconds`，Runbook、AI 上下文和 CLI/MCP `diagnostics` 可直接消费这波失败的持续时间，后续做排序和趋势统计不必重复计算。
- 连续失败匹配方式：`RepeatedFailureDiagnostic` 新增 `matchKind`，区分 `exact` 完全重复和 `normalized` 归一化指纹命中，帮助 Runbook、AI 和外部工具判断同类失败聚合的可信度。
- 建议排查命令：`CommandBlockDiagnostics` 新增 `suggestedNextCommand`，按端口占用、权限、缺文件、git fatal 和连续失败等常见场景生成保守的只读排查命令，并同步给 Runbook、AI 上下文和 CLI/MCP `diagnostics`，继续保持由用户确认后执行。
- CLI/MCP 命令块读取：已新增 `museterm commands` 和 MCP `read_commands`。
- 命令搜索 UI：已提供右侧命令搜索面板，可按命令、目录和输出搜索，并支持失败过滤。
- 滚屏历史搜索：命令搜索面板会同时搜索当前标签原始滚屏历史，展示脱敏后的命中片段和命中数量，覆盖尚未形成结构化命令块的输出。
- 输出洞察第一版：命令块会轻量识别错误、警告、URL、文件路径、JSON、YAML、堆栈和 commit hash，并可复制按类型整理的输出摘要；JSON 输出摘要会附带格式化后的 pretty JSON，不改变终端原始渲染。
- AI Explain 上下文与真实调用：已支持从命令块复制包含 Provider/Model/Base URL 的 AI 上下文，且不包含 API Key；也可直接请求 Provider 解释单条命令块，覆盖 OpenAI 兼容接口、Anthropic、Google Gemini、Azure OpenAI、OpenRouter、Ollama 和自定义端点。
- AI Explain 流式输出：解释请求使用 Provider SSE 流式接口，结果面板会随响应到达增量显示。
- 本地 zsh/bash/fish shell integration：zsh 通过 MuseTerm 专用启动文件挂载 `preexec/precmd` hook，fish 通过启动 hook 挂载 `fish_preexec/fish_postexec`，可解析不可见 OSC marker 以回填命令开始和真实退出码；bash 通过生成 rcfile 挂载 `PROMPT_COMMAND` 回填退出码，命令开始暂时降级为用户输入推断；其他 shell 暂时降级为保守识别。
- 安全模式第一版：SSH profile 已支持开发/预发/生产环境标记，侧栏和标签行展示环境短标；多行粘贴与高危命令在写入 PTY 前弹窗确认，取消后不会执行。
- 多行粘贴确认说明：确认弹窗新增触发原因文案，明确多行 shell 文本发送到终端后可能连续执行命令，提醒用户检查预览符合预期后再发送。
- 多行粘贴说明测试化：`SafetyInputAnalyzer` 统一生成多行粘贴确认说明，测试覆盖非空行数、触发原因和段落分隔，避免弹窗文案在后续改动中退化。
- 远端命令追踪确认：多行粘贴确认会识别 MuseTerm 远端 SSH 命令追踪初始化脚本，改用专门标题、说明和“启用追踪”按钮解释临时 shell hook 的用途、边界和会话级失效条件，并用真实初始化脚本测试防退化。
- 路径参数转义键入：终端右键菜单可将当前选中文本作为 shell 路径参数填入命令行，普通文件名会单引号转义，已有 `$'...'` / 反斜杠转义形式会原样保留，空选择和多行选择不会启用该动作。
- 安全模式自定义规则：行为设置中已支持自定义高危命令规则，每行一条，普通文本按包含匹配，`regex:` 前缀按正则匹配，命中后会显示具体规则并要求确认。
- 安全模式按 profile 覆盖：SSH profile 已支持安全确认策略，可继承全局、强制确认或关闭确认；生产环境默认强制确认。
- 敏感输出脱敏提示：命令搜索面板会提示疑似敏感输出数量，命令卡片显示警示；脱敏开启时展示、复制、导出和 AI 上下文均使用脱敏内容。
- 敏感信息脱敏增强：`RunbookSensitiveRedactor` 已独立到专用文件，并扩展 GitHub fine-grained token、Google API Key、npm token、Stripe 风格 key、命令行密钥参数、URL basic-auth 密码和 PEM 私钥块脱敏测试。
- Runbook 导出与回放第一版：命令搜索面板可将当前过滤结果导出为 Markdown，支持备注、敏感信息脱敏、回放脚本、复制到剪贴板和保存 `.md` 文件；单条命令可填入当前终端待执行，但不会自动回车。
- Runbook 导出器拆分与回放测试：Markdown 导出、诊断摘要写入、回放脚本生成和路径变量参数化已从 `ContentView.swift` 拆分到 `RunbookMarkdownExporter.swift`，并新增测试覆盖回放脚本参数化、逐步确认包装、敏感命令参数脱敏和空命令过滤。
- 任务与端口面板第一版：右侧面板可查看运行中的结构化命令块和本机监听 TCP 端口，支持刷新、打开 `localhost` URL、复制监听地址，并将 `kill PID` 填入当前终端等待用户确认。
- 项目工作区恢复第一版：标签菜单可保存当前本地/SSH 标签、选中标签和本地目录，并可确认后从上次快照恢复；本地 shell 会直接启动到保存目录，SSH 标签恢复连接入口，运行中进程不做冻结恢复。
- Runbook 回放安全增强：回放脚本可将本机 Home 与工作目录参数化为 `RUNBOOK_HOME` / `RUNBOOK_WORKDIR`，并默认用 `run_step` 逐条确认后再执行命令。
- Runbook 变量编辑体验：命令搜索面板可编辑 `RUNBOOK_HOME` 与 `RUNBOOK_WORKDIR` 默认值，复制回放、复制 Runbook 和保存 Markdown 共用同一套变量覆盖值。
- AI Explain 上下文选择：命令搜索面板可在只发命令、当前命令块、当前过滤结果摘要之间切换上下文范围，复制 AI 上下文和直接解释共用同一设置。
- AI Explain 客户端拆分：Provider 配置校验、OpenAI/Anthropic/Gemini 兼容流式请求、SSE 增量解析和错误映射已从 `ContentView.swift` 拆分到 `AIExplainClient.swift`，并补充本地配置校验测试，让主视图文件降到 2000 行以下。
- 统计娱乐系统第一版：任务与端口面板显示本次会话命令数、失败数、运行中命令、端口数、最长耗时和轻量成就徽章。
- 统计持久化第一版：任务与端口面板显示“今天”统计，跨 App 重启累计当天已结束命令数、失败数和最长命令耗时。
- 统计持久化拆分：每日命令统计的本地 JSON 读写已从 `TaskPortPanel.swift` 拆分到 `PersistentCommandStatsStore.swift`，让任务与端口面板文件降到 2000 行以下。
- 安全输入分析拆分：多行粘贴识别、高危命令规则、自定义文本/正则规则解析和确认预览控件已从 `TerminalHostView.swift` 拆分到 `TerminalSafetyInputAnalyzer.swift`，并补充单元测试，让终端宿主视图降到 2000 行以下。
- 路径参数转义拆分：`TerminalShellArgumentEscaper` 已从 `TerminalSafetyInputAnalyzer.swift` 拆分到独立文件，路径参数转义逻辑与多行/高危输入分析分离，现有转义测试继续覆盖行为不变。
- 路径参数转义测试拆分：`TerminalShellArgumentEscaper` 的单元测试已迁移到独立 `TerminalShellArgumentEscaperTests.swift`，转义行为测试与多行/高危输入分析测试各归其位。
- Shell marker 解析拆分：`TerminalShellIntegrationParser` 已从 `TerminalHostView.swift` 拆分到独立文件，终端宿主视图降到 2000 行以下，后续增强 marker 解析不再继续拖大视图文件。
- Shell marker 分片测试：`TerminalShellIntegrationParser` 已补充边界测试，覆盖 marker 前缀跨 PTY 数据块拆分、无效 marker 后继续解析后续有效 marker，以及普通终端输出不产生事件。
- Shell marker 终止符兼容：`TerminalShellIntegrationParser` 同时支持 BEL 与 `ESC \\` 两种 OSC marker 终止符，并覆盖跨数据块 ST 终止、BEL/ST 混合 marker 的解析顺序。
- 远端 shell/进程工具第一版：SSH profile 可为远端 bash/zsh 会话临时注入 shell hook 追踪退出码；任务与端口面板可向本地或 SSH 标签填入端口扫描、进程列表、PID 详情和终止命令，本机端口 PID 操作限定到本地标签以避免误杀。

仍需继续增强的规划项包括：远端 fish、nested shell/tmux 场景下的 shell integration 准确性，以及更完整的进程树/端口详情视图。

## 基于 SwiftTerm 的能力边界

### 总体判断

MuseTerm 基于 SwiftTerm 实现这些功能是可行的，而且当前项目已经接入了不少关键钩子：

- `LocalProcessTerminalViewDelegate`：可获取标题、当前目录、窗口尺寸、进程退出等事件。
- `TerminalViewDelegate.send`：可观察用户发往 PTY 的输入，当前录制功能已经在使用这条链路。
- `Terminal.getLine(row:)`：可读取当前屏幕文本。
- `Terminal.getBufferAsData()`：可读取滚屏历史文本。
- `LocalProcessTerminalView.process`：可向本地 PTY 发送输入，也可检查进程运行状态。
- 自定义 `FocusableLocalProcessTerminalView`：已经包装了焦点、粘贴、输入录制、ECHO 检测和 delegate router。

因此，SwiftTerm 对“终端渲染、PTY 输入输出、屏幕/历史读取、标题和目录事件”支持较好。真正的边界在于：SwiftTerm 是终端模拟器，不是 shell 语义引擎。它天然不知道“一条命令从哪里开始、在哪里结束、退出码是多少、当前命令是不是交互式程序”。这些信息如果只靠滚屏文本反推，会不稳定。

### SwiftTerm 可行性决策矩阵

| 设想能力 | SwiftTerm 直接支撑 | MuseTerm 外层职责 | MVP 做法 | 主要风险 | 可行性 |
| --- | --- | --- | --- | --- | --- |
| 结构化命令块 | PTY 输入、滚屏文本、标题和目录事件 | `CommandBlock` 生命周期、输出摘要、退出状态归档 | 继续以 shell marker 为主，输入推断为降级路径 | tmux、REPL、全屏 TUI 无法可靠切块 | 高 |
| 命令历史与输出搜索 | 当前屏幕与 scrollback 读取 | 命令块索引、脱敏、过滤、异步搜索 | 当前标签内存搜索 + 滚屏片段搜索 | 大输出卡顿、历史定位精度有限 | 高 |
| AI Explain / MCP 上下文 | 提供屏幕、历史、输入桥 | 结构化上下文、敏感信息脱敏、Provider 请求 | 只把结构化摘要和脱敏输出交给 AI | 输出含密钥、AI 建议误导 | 高 |
| Runbook 导出与命令回放 | 可向 PTY 填入文本 | Markdown 生成、变量参数化、逐步确认 | 导出当前过滤命令块，回放只填入或逐步确认 | 把历史误当可复现流程 | 高 |
| 安全模式与高危命令预警 | 输入写入 PTY 前可被外层拦截 | 规则匹配、profile 环境、确认弹窗、粘贴预览 | 多行粘贴和高危文本/正则确认 | 误伤熟练用户、TUI 粘贴体验 | 中高 |
| 项目级工作区 | 可创建本地 shell 和 SSH 终端 | 标签快照、目录恢复、profile 快照、恢复确认 | 恢复标签、目录和连接入口 | 无法恢复运行中进程现场 | 中高 |
| 任务与端口面板 | 可知道命令是否仍在运行 | 端口扫描、进程详情、只填命令不直接执行 | 本地 `lsof` + 当前命令块运行态 | 权限差异、误杀进程风险 | 中 |
| SSH/远端环境识别 | SSH 会话仍是字节流 | profile 环境、远端 hook、只读探针 | 以 profile 标记为准，远端 hook 可选增强 | nested SSH、远端 shell 差异 | 中 |
| 命令回放录像 | 可记录输入输出字节流 | 时间轴、压缩、脱敏、播放器 | 第一版只导出 Runbook，不做像素级录像 | 体积、隐私、重放时序复杂 | 低到中 |
| 协作共享终端 | 无直接协作协议 | 权限、审计、同步、冲突处理 | 暂不做，先做好本机导出与 MCP | 安全边界重，产品成本高 | 低 |

### 实现层分工

| 层级 | 应该承担 | 不应该承担 |
| --- | --- | --- |
| SwiftTerm | 终端模拟、PTY I/O、ANSI 渲染、屏幕和滚屏 buffer、标题与目录事件 | 判断 shell 语义、理解命令意图、识别生产环境、决定是否安全 |
| Shell integration | 命令开始、命令结束、退出码、当前目录、远端 shell hook | 修改用户真实启动文件、自动执行修复命令、假装覆盖所有 shell |
| MuseTerm App 层 | 命令块模型、搜索、Runbook、安全确认、AI 上下文、工作区快照 | 破坏原生终端输入输出节奏、把提示做成强制工作流 |
| CLI/MCP 层 | 暴露屏幕、历史、命令块、诊断摘要和可确认的输入请求 | 绕过用户确认直接执行高危动作 |

### 优先落地口径

后续小切片优先按这个顺序推进：

1. 继续深化 `CommandBlockDiagnostics`，把失败诊断从“能看到”推进到“能复盘、能排序、能被外部工具稳定消费”。
2. 增强 shell integration 准确性，但每一步都保留无 hook 降级路径。
3. 把搜索、Runbook、AI 上下文优先接到结构化字段，而不是重复解析滚屏文本。
4. 安全功能保持“填入等待确认”和“执行前确认”的边界，不做自动修复。
5. 对 tmux、REPL、全屏 TUI、nested SSH 明确降级，不把边缘场景伪装成已完全支持。

### MVP 验证清单

每次推进这组能力时，至少检查以下场景：

- 普通本地 zsh/fish：命令开始、结束、退出码、cwd、输出摘要准确。
- 本地 bash：退出码准确，命令开始允许用输入推断降级。
- SSH zsh/bash：远端 hook 不写入远端启动文件，退出码和 cwd 能回传或安全降级。
- 多行粘贴：命令不会绕过高危确认，取消后不会写入 PTY。
- TUI/REPL：不会生成大量错误 command block，不会错误自动执行建议动作。
- 敏感输出：Runbook、AI 上下文、MCP 快照在脱敏开启时不暴露 token/password/API Key。
- 大输出：搜索、诊断摘要和导出都应截断或异步处理，不能卡住主线程。

### 能很好完成的功能

| 功能 | 判断 | 原因 |
| --- | --- | --- |
| 当前屏幕读取 | 很适合 | 已能通过 `terminal.getLine(row:)` 拼出可见屏幕文本。 |
| 滚屏历史读取 | 很适合 | 已能通过 `terminal.getBufferAsData()` 导出历史文本，MCP bridge 已在使用。 |
| 用户输入观察 | 很适合 | 当前录制功能已覆盖 `send(source:data:)`，还能结合 ECHO 判断敏感输入。 |
| 终端标题/当前目录同步 | 很适合 | SwiftTerm delegate 已提供 `setTerminalTitle` 与 `hostCurrentDirectoryUpdate`。 |
| 多标签、SSH、主题、字体、光标 | 很适合 | 这些属于外壳 UI 和终端配置，当前项目已经验证过。 |
| 历史/输出搜索 | 适合 | 可先基于 buffer 文本和 command block 做内存搜索，后续再持久化。 |
| MCP 上下文导出 | 适合 | 已有状态文件与请求/响应目录，扩展结构化字段即可。 |

### 需要补强才能做好的功能

| 功能 | 判断 | 需要补强 |
| --- | --- | --- |
| 结构化命令块 | 能做，但不能只靠 SwiftTerm | 需要 shell integration 输出不可见 marker，标记命令开始、结束、退出码和当前目录。 |
| 失败命令摘要 | 能做 | 依赖结构化命令块，否则只能从最近输出猜测。 |
| Runbook 导出 | 能做 | 依赖 command block 的命令、输出、退出码、耗时等字段。 |
| 高危命令预警 | 能做 | 输入发送前可拦截，但要区分普通 shell、TUI、REPL、多行粘贴。 |
| 生产环境识别 | 能做 | 需要 SSH profile 增加环境字段，不能靠主机名猜测。 |
| 项目工作区恢复 | 能做 | 本地目录和 SSH profile 可恢复；不能恢复已运行进程的真实状态。 |
| 端口/任务面板 | 能做 | 长任务可来自 command block，端口信息需要系统命令或 Network framework 补充。 |

### 不建议强做或第一版不做的功能

| 功能 | 原因 |
| --- | --- |
| 完美识别所有 shell/REPL/TUI 的命令边界 | SwiftTerm 看到的是字节流和屏幕状态，不知道 shell 内部语义。 |
| 精准恢复上次进程现场 | PTY 进程不可被普通 App 无损冻结和恢复；只能恢复标签、目录和连接入口。 |
| 自动执行 AI 建议命令 | 安全风险高，尤其是 SSH/生产环境；必须用户确认。 |
| 强依赖滚屏文本定位跳转 | SwiftTerm 是否能精准滚动到历史某行需要单独验证；初版可先展示搜索片段。 |

### 推荐技术路线

1. 保留 SwiftTerm 作为终端渲染和 PTY I/O 核心，不 fork SwiftTerm。
2. 在 MuseTerm 外层建立 `CommandBlock` 模型，负责命令语义。
3. 初版用输入事件和历史增量做保守识别，尽快可视化最近命令。
4. 第二步加入 shell integration：对 zsh/bash/fish 注入轻量 prompt hook，通过 OSC 或私有不可见转义序列回传命令边界、退出码和目录。
5. tmux、vim、ssh nested shell、REPL 等场景默认降级为普通滚屏，不承诺结构化准确。
6. 将结构化 command block 同步暴露给 `TerminalToolBridge`，让 MCP/AI 使用结构化上下文，而不是解析一大段滚屏文本。

### 结论

这些功能与 SwiftTerm 的关系可以概括为：SwiftTerm 负责“终端像终端一样可靠”，MuseTerm 负责“把终端工作过程结构化”。只要不把 SwiftTerm 当成 shell 语义分析器，大部分规划功能都能较好完成；如果试图纯靠 SwiftTerm buffer 猜命令边界，就会在复杂 shell、tmux、REPL 和全屏程序里翻车。

## P0：结构化命令块与执行摘要

### 产品设想

终端仍然正常显示原始输出，但 MuseTerm 在旁路记录每次命令执行边界，形成独立的 command block：

- 命令文本
- 开始时间、结束时间、耗时
- 当前目录
- 退出码
- 输出摘要与最后 N 行
- 是否来自 SSH、是否在生产环境
- 可操作项：复制命令、复制输出摘要、重跑、收藏、生成 Runbook 片段

### 为什么优先

这是后续历史搜索、AI 解释、Runbook、安全分析的基础层。没有结构化命令块，很多功能只能从滚屏文本里猜，越做越像拆毛衣。

### 现有基础

- `TerminalSession` 已维护标签状态、当前目录、退出状态。
- `TerminalHostController` 已能读取可见屏幕与历史文本。
- `TerminalToolBridge` 已定期导出 `screen` 和 `history`，说明终端文本采集链路可用。
- 终端录制功能已具备输入事件捕获经验，可复用部分思路。

### 初版范围

- 本地维护内存级 command block 列表，先不做持久化。
- 识别用户按 Enter 提交的命令。
- 记录命令提交前后的历史文本差异作为该命令输出。
- 通过 shell prompt marker 或最小侵入的 shell integration 提升边界识别准确率。
- 在侧栏或右侧轻量 inspector 展示最近命令摘要。

### 技术可行性

可行性：高。

关键点不是 UI，而是命令边界识别。建议分两步：

1. 无 shell integration 的保守方案：基于输入事件、Enter、历史文本增量和退出状态做初步 block。
2. shell integration 方案：为 zsh/bash/fish 注入轻量 prompt marker，输出不可见转义序列来标记命令开始、结束、退出码和目录。

### 风险

- 用户自定义 shell、tmux、vim、全屏 TUI 会干扰命令边界。
- 多行命令、交互式命令、REPL 不能简单按 Enter 切块。
- 历史文本差异如果不做限流，可能造成内存增长。

### 验收标准

- 普通 zsh/bash 下，`pwd`、`git status`、`yarn test` 能形成准确 block。
- 退出码和耗时显示正确。
- 交互式程序退出后不会生成大量错误 block。
- 每个标签保留最近可配置数量的 block，默认例如 200 条。

## P0：历史与输出搜索

### 产品设想

提供全局搜索入口，支持按以下维度过滤：

- 命令文本
- 输出内容
- 当前项目目录
- 标签 / SSH 主机
- 退出码成功或失败
- 时间范围
- 收藏命令

### 为什么优先

这是终端软件最常见但仍然做得不够好的痛点。尤其是输出也能搜，会直接改变用户回溯问题的方式。

### 现有基础

- `TerminalToolBridge` 已能导出每个标签历史文本。
- command block 完成后，可把搜索对象从“整段滚屏”升级为“命令记录”。
- 当前目录和标签标题已有基础数据。

### 初版范围

- 先做当前运行期搜索，不做跨重启持久化。
- 搜索当前标签历史与 command block。
- 支持 `Cmd+F` 打开搜索面板。
- 搜索结果可跳转到对应 command block 或展示输出片段。

### 技术可行性

可行性：高。

Swift 侧可以先用内存数组和字符串匹配实现；后续如果要跨重启和大规模搜索，再引入 SQLite FTS。第一版不必一上来就把数据库请上主席台。

### 风险

- 当前 SwiftTerm 滚屏定位能力需要验证，初版可能只能展示片段而不能精准滚动到原位置。
- 大输出搜索要做截断与异步，避免主线程卡顿。

### 验收标准

- 能搜索当前标签最近输出和命令。
- 搜索大于 10 万字符历史时 UI 不明显卡顿。
- 失败命令可按退出码过滤。

## P1：项目工作区恢复

### 产品设想

以项目目录为单位保存工作区：

- 标签列表
- 每个标签的启动目录
- SSH profile
- 常用命令
- 侧栏展开状态
- 可选：窗口大小与分屏布局

用户打开项目后，可一键恢复上次开发现场。

### 为什么优先

MuseTerm 已经有多标签与 SSH，这个功能能把“标签集合”升级为“项目工作台”。它对日常开发很有粘性。

### 现有基础

- `TerminalWorkspace` 已管理标签数组与当前选择。
- SSH profile 已可序列化保存。
- 终端录制快捷指令已有 JSON 存储经验。
- 当前目录已同步到 `TerminalSession.currentDirectory`。

### 初版范围

- 保存和恢复本地标签的目录。
- 保存和恢复 SSH 标签所使用的 profile 快照。
- 先不恢复滚屏内容，不自动重放历史命令。
- 提供“保存当前工作区”和“打开工作区”入口。

### 技术可行性

可行性：中高。

主要工作是数据模型和 UI。恢复本地 shell 较简单；恢复 SSH 需要处理 profile 被删除或修改的情况；恢复命令历史不建议第一版做，容易误导用户以为进程也被恢复。

### 当前状态

v1.24.0 已完成第一版：工作区快照保存到 `~/Library/Application Support/MuseTerm/Workspaces/last-workspace.json`，包含本地标签目录、SSH profile 快照和选中标签索引。菜单提供 `Option+Cmd+S` 保存与 `Option+Cmd+O` 恢复；恢复前会确认当前标签将被关闭，且不会恢复已运行进程现场。旧目录不存在时本地标签降级回默认 Home 启动。

### 风险

- 自动恢复远端连接可能带来安全和凭据体验问题，应默认需要用户确认。
- 旧目录不存在时要有清晰降级。
- 工作区与现有偏好、快捷指令存储要边界清楚。

### 验收标准

- 能保存当前本地标签目录并恢复。
- SSH profile 缺失时提示而不是崩溃。
- 恢复后标签标题、目录、SSH 目标基本正确。

## P1：安全模式与高危命令预警

### 产品设想

识别风险上下文和命令：

- 生产环境标签显示明显但克制的 `PROD` 标识。
- 粘贴多行命令前预览。
- 高危命令二次确认，例如 `rm -rf /`、`kubectl delete`、`terraform destroy`、`DROP DATABASE`。
- 输出中疑似 token、key、JWT 时做本地脱敏提示。

### 为什么优先

终端的核心价值之一是“让我敢用”。安全护栏是信任感，不是摆设。

### 现有基础

- SSH profile 已有目标主机信息，可加环境标签。
- `TerminalHostController.sendProcessInput` 是输入发送路径，可在这里做拦截前置。
- 录制功能已有“不回显输入进 Keychain”的敏感信息处理意识。

### 初版范围

- SSH profile 增加环境字段：local / dev / staging / prod。
- 生产环境标签在侧栏和终端顶部显示状态条。
- 粘贴多行文本时弹出预览确认。
- 规则库本地内置，先不做复杂 DSL。

### 技术可行性

可行性：中。

UI 和数据模型不难，难点在于不要误伤正常输入。所有拦截都应可关闭、可绕过、可按 profile 配置。

### 风险

- 高危命令识别不可能百分百准确，必须把文案定位为提醒，不是安全证明。
- 拦截用户输入会影响熟练用户的流畅感。
- TUI 程序中的粘贴不应被错误改写。

### 验收标准

- prod profile 有稳定可见标识。
- 粘贴两行以上命令时可预览、确认、取消。
- 命中高危规则时需要二次确认。

## P1：AI Explain / MCP 解释面板

### 产品设想

右侧 inspector 提供上下文解释能力：

- 解释当前命令在做什么。
- 命令失败后总结错误原因。
- 根据最近输出建议下一步排查命令。
- 可把 command block 导出给外部 AI 工具。

### 为什么优先

项目已经有 CLI/MCP 工具桥，这是 MuseTerm 的天然优势。与其内置重型 AI 账号系统，不如先做好“可被 AI 工具读懂和操作”的本机接口。

### 现有基础

- `TerminalToolBridge` 已导出 app 版本、标签、屏幕、历史文本。
- CLI/MCP 已能向指定标签发送文本或控制键。
- command block 完成后，可把 AI 上下文从滚屏文本升级为结构化数据。

### 初版范围

- App 内只做本地解释面板壳，不直接绑定云端模型。
- 扩展 `TerminalToolState`，增加最近 command blocks。
- CLI 增加读取最近失败命令的能力。
- 面板提供“复制上下文给 AI”和“从 MCP 工具读取”的入口。

### 技术可行性

可行性：中。

如果不内置模型调用，技术复杂度可控。真正要内置 AI，需要处理模型选择、密钥保存、网络权限、费用和隐私，这些不适合第一版。

### 当前状态

v1.26.0 已完成真实 AI Explain、上下文选择与流式输出：设置页可配置 Provider、模型、Base URL 和 Keychain API Key；命令搜索面板可直接解释单条命令块，也可复制 AI 上下文。上下文范围支持只发命令、当前命令块、当前过滤结果摘要三档，脱敏开关会同时作用于复制和请求。解释请求会使用 OpenAI 兼容、Azure OpenAI、OpenRouter、Ollama、自定义端点、Anthropic 和 Google Gemini 的 SSE 流式接口，结果面板随响应到达增量显示。

### 风险

- 终端输出可能包含敏感信息，导出上下文前必须明确提示并支持脱敏。
- AI 建议可能错误，不能自动执行高风险命令。
- MCP 状态文件体积需要控制。

### 验收标准

- CLI/MCP 能读取最近命令块、失败摘要和当前屏幕。
- App 内能一键复制脱敏后的失败上下文。
- 所有 AI 相关执行动作默认需要用户确认。

## P2：任务、端口与本地服务面板

### 产品设想

侧栏或底部显示：

- 正在运行的长任务
- 本地监听端口
- 常见 dev server URL
- 任务耗时、退出码、最后输出
- 一键打开浏览器或停止进程

### 技术可行性

可行性：中。

长任务可以基于 command block 的持续时间识别；端口扫描需要调用系统工具或 Network framework。停止进程必须谨慎，第一版可以只展示和打开 URL。

### 当前状态

v1.20.0 已完成第一版：右侧任务与端口面板会列出当前运行中的结构化命令块，并通过 `lsof` 扫描本机监听 TCP 端口；端口卡片支持刷新、打开 `http://127.0.0.1:<port>`、复制监听地址，以及把 `kill PID` 填入当前终端等待用户回车执行。第一版不直接结束进程，也暂不扫描远端 SSH 主机。

### 主要风险

- 系统权限和不同 macOS 版本下端口归属识别差异。
- 误杀进程风险高，不建议早期提供“一键 kill”。

## P2：Runbook 导出与命令回放

### 产品设想

把一组 command blocks 导出为 Markdown：

- 命令
- 关键输出摘要
- 成功/失败状态
- 手写备注
- 环境信息

也可以把命令序列保存为可重跑的 workflow，但默认不自动执行危险命令。

### 技术可行性

可行性：中。

已有终端录制和 command block 后，导出 Markdown 很直接；难点是“重放”不能等同于“复制粘贴所有命令”，需要确认、参数化和敏感输入保护。

### 当前状态

v1.25.0 已完成回放脚本增强：Runbook 可选将本机 Home 和工作目录抽成 `RUNBOOK_HOME` / `RUNBOOK_WORKDIR`，并默认生成逐条确认的 `run_step` 包装。命令搜索面板可编辑两个变量的默认值；复制回放脚本、复制 Runbook 和保存 Markdown 会共用同一套变量覆盖值，导出的 Markdown 也会记录变量默认值。后续仍可继续增强命令分组和跨主机适配。

## P3：成就、统计与轻娱乐系统

### 产品设想

只作为轻量边角料：

- 今日命令数
- 最常失败命令
- 最常用项目
- 长任务完成提示
- 小型成就 toast

### 技术可行性

可行性：高。

依赖 command block 数据即可实现。注意默认克制，不能喧宾夺主。

### 当前状态

v1.27.0 已完成第一版：任务与端口面板顶部展示本次运行期统计，包括命令总数、失败数、运行中命令、监听端口、最长命令耗时，以及“十条命令”“零失败”“服务在线”“长任务”等轻量徽章。面板还新增“今天”统计，跨 App 重启累计当天已结束命令数、失败数和最长命令耗时；本地聚合数据保存到 `~/Library/Application Support/MuseTerm/Stats/daily-command-stats.json`。

## 推荐实施顺序

1. 建立 `CommandBlock` 数据模型和最小 shell integration。
2. 在当前标签内展示最近命令块与执行摘要。
3. 做当前标签搜索，支持搜索命令和输出片段。
4. 把 command block 暴露给 CLI/MCP。
5. 增加失败命令上下文复制与脱敏。
6. 增加 SSH profile 环境字段与 `PROD` 标识。
7. 增加多行粘贴预览与高危命令确认。
8. 已完成项目工作区保存与恢复第一版。
9. 再进入任务/端口面板增强、Runbook、统计娱乐功能。

## 数据模型草案

```swift
struct CommandBlock: Identifiable, Codable, Equatable {
    let id: UUID
    let tabID: UUID
    let command: String
    let workingDirectory: String?
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var outputTail: String
    var outputCharacterCount: Int
    var isInteractive: Bool
    var environmentKind: TerminalEnvironmentKind
}

enum TerminalEnvironmentKind: String, Codable {
    case local
    case development
    case staging
    case production
}
```

第一版只需内存保存；后续跨重启搜索可迁移到 SQLite。

## 非目标

- 第一版不做内置云端 AI 账号与模型计费。
- 第一版不自动执行 AI 建议命令。
- 第一版不试图完美支持所有 shell、tmux、REPL 和全屏 TUI。
- 第一版不恢复已结束进程或伪造历史运行状态。

## 总体结论

最值得优先做的是“结构化命令块 + 历史/输出搜索 + MCP 上下文增强”。这三项互相支撑，且与现有架构贴合。它们完成后，安全模式、AI Explain、Runbook、任务面板都会变成自然延伸，而不是各自单飞。
