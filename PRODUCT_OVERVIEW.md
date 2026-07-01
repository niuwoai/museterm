# Product Overview

> 最后更新：2026-07-01 | 当前版本：v1.143.0

## 项目简介

MuseTerm 是一个轻快的 macOS 多标签终端应用，使用 SwiftUI 构建外壳界面，并通过 SwiftTerm 提供本地 shell 终端能力。

## 核心功能

- 多标签终端：左侧纵向标签列表，支持新建、切换、关闭标签；侧栏标题使用两行紧凑工具区，应用名保持单行显示；标签行会显示当前会话 shell 短标；关闭按钮仅在鼠标悬停到整块标签行时显示，并可通过侧栏图标或设置开关折叠列表。
- 标签快捷键：支持 `Cmd+T` 新建、`Cmd+W` 关闭当前标签（关掉最后一个标签即关闭窗口，所有窗口关闭后退出 App）、`Cmd+Shift+[` / `Cmd+Shift+]` 前后切换，以及 `Cmd+1` 到 `Cmd+9` 直达标签；标签标题后用浅色 `⌘N` 标注对应快捷键。
- 标签 shell 标识：本地和 SSH 会话会在侧栏标签摘要前显示轻量 shell badge，例如 zsh、bash、fish，方便区分不同 shell 环境。
- 工作区保存与恢复：标签菜单支持 `Option+Cmd+S` 保存当前本地/SSH 标签、选中标签和本地工作目录，`Option+Cmd+O` 可确认后从上次快照恢复；本地 shell 会直接启动到已保存目录，SSH 标签恢复连接入口，但不会冻结或恢复已经运行的进程现场。
- 快速建签：预热下一份终端控制器，并延后补位以减少新建标签后的主线程阻塞。
- 本地 shell：每个标签启动一个独立登录 shell。
- SSH 主机：侧栏可保存并打开 SSH profile，单击主机名整块区域即可直接连接，「…」菜单仅保留编辑与删除；支持用户名、端口、不同密钥文件、额外 SSH 选项、远端 shell hook 和连接后启动命令。
- SSH 环境标记：SSH profile 可标记开发、预发、生产环境，侧栏与标签行会显示 DEV/STG/PROD 短标。
- 跳转机：SSH profile 支持一跳、二跳、三跳及更多多跳路由，每一跳可配置自己的用户、端口和密钥。
- 终端录制：侧栏可录制当前终端输入，生成可回放的终端捷径，并保留原始输入延迟。
- 录制编辑：录制捷径支持改名、删除和 JSON 编辑；不回显输入通过 Keychain 保存，JSON 仅保存引用。
- rz/sz 文件传输：侧栏提供上传和下载入口，上传可选择本机文件并通过远端 `rz` 接收，下载会先选择本机保存文件，再输入远端路径并通过远端 `sz` 保存到本机。
- 传输进度：上传下载时侧栏显示传输状态、文件名和百分比；如果本机 `rz`/`sz` 没有输出百分比，则显示不确定进度条。
- 传输依赖提示：开始传输前检查远端 `rz`/`sz` 支持；远端缺少 `lrzsz` 时会在终端提示常见 Linux 发行版和 macOS 的安装命令，本机缺少 `lrzsz` 时提示使用 Homebrew 安装。
- 标签保活：切换标签时终端渲染视图常驻，避免已有输出丢失或变空白。
- 终端状态：自动同步终端标题、当前目录和进程退出状态。
- 结构化命令块：旁路记录用户提交的命令、工作目录、时间、输出尾部、紧凑输出摘要、命令开始来源、退出/中断状态和完成来源，可区分 shell hook、用户输入推断、进程退出兜底、用户中断与覆盖结束，为历史搜索、Runbook 和 AI Explain 提供基础数据。
- Shell integration：本地 zsh 和 fish 会加载 MuseTerm 专用 preexec/postexec hook 以回传命令开始和真实退出码，本地 bash 通过生成 rcfile 挂载 `PROMPT_COMMAND` 回传退出码；本地会话会记录登录 shell 名，SSH 启动时会先发送轻量 shell 探测 marker，把 `$SHELL` 归一化为 `zsh` / `bash` / `fish` 等稳定 shell 名；SSH profile 可为远端 zsh 回传命令开始和退出码，为远端 bash 回传退出码，不写入远端启动文件；其他 shell 暂时使用保守识别。
- 命令搜索面板：右侧检查面板可搜索当前标签的命令、目录、命令块输出和原始滚屏历史，支持仅看失败命令；命令块会轻量识别错误、警告、URL、文件路径、JSON/YAML、堆栈和 commit hash，失败命令卡片会直接展示首条关键诊断行，并可复制命令、输出尾部、输出摘要、滚屏片段或 AI 上下文；JSON 输出摘要会自动带上格式化后的 pretty JSON。
- 任务与端口面板：右侧面板可查看运行中的结构化命令块和本机监听 TCP 端口，支持刷新、按进程名/PID/监听地址/端口号/常见服务名/进程工作目录过滤端口，端口行会显示服务名 badge 与工作目录名；`lsof` 返回的 `\xNN` / 八进制字节转义会按 UTF-8 还原，中文进程名和中文目录可正常展示与搜索；支持打开 `localhost` URL、复制监听地址，并可将本机 `kill PID` 填入本地终端等待确认执行；当前会话工具可向本地或 SSH 标签填入端口扫描、进程列表、PID 详情、SIGTERM 和 SIGKILL 命令；面板还展示本次会话命令统计、当天跨重启累计统计、最长耗时、最近失败诊断、连续同类失败提醒和轻量成就徽章。
- AI Explain：命令搜索面板可直接对单条命令块请求 AI 解释，覆盖命令意图、输出状态、失败原因、风险点和下一步建议，并在 Provider 返回内容时流式增量显示；AI 上下文可选择只发命令、当前命令块或当前过滤结果摘要；支持 OpenAI 兼容接口、Anthropic、Google Gemini、Azure OpenAI、OpenRouter、Ollama 和自定义端点。
- Runbook 导出与回放：命令搜索面板可把当前过滤出的命令块生成 Markdown，支持备注、敏感信息脱敏、输出摘要、失败诊断、最近失败命令 ID、最近失败诊断命令 ID、最近失败工作目录、最近失败诊断工作目录、最近失败输出尾部行号与证据行、最近失败退出码、最近失败耗时、最近失败命令来源、最近失败完成来源、诊断优先级分数与因素、诊断分类、分类依据与可信度、连续同类失败摘要、连续失败全部命令块 ID、唯一命令、唯一工作目录、上下文变化标记、稳定性枚举与变化原因、平均失败间隔、最近失败间隔、失败节奏分类、首次/最近命令文本、命令 ID、工作目录、输出尾部行号与证据行、建议排查命令、结构化建议排查动作、稳定动作 ID、动作来源分类与可信度、动作优先级分数与因素、动作证据锚点、动作作用域、动作预期结果类型、动作预期结果字段、动作预期结果信号、动作结果解析提示、动作结果解释提示、动作结果决策提示、动作结果局限提示、动作敏感结果字段、动作结果脱敏提示、动作结果刷新触发条件、动作结果隐私级别、动作结果分享策略、动作结果保留策略、动作执行模式、执行目标、动作结果适用范围、动作结果新鲜度策略、动作结果复用键字段、动作结果复用策略、动作结果复用验证检查、重试条件、执行前检查、自动化护栏、用户决策点、完成判据、动作观察信号、动作降级步骤、回放脚本、复制到剪贴板和保存为 `.md` 文件；回放脚本可参数化本机路径，并可编辑 `RUNBOOK_HOME` / `RUNBOOK_WORKDIR` 默认值，默认对每条命令逐步确认；单条命令可填入当前终端待执行，但不会自动回车；Runbook 会记录疑似敏感输出数量、脱敏状态、参数化状态、变量默认值、逐步确认状态，以及每条命令的错误/警告、URL、路径、commit 和堆栈线索。
- 安全确认：可在设置中开启/关闭多行粘贴确认和高危命令确认；SSH profile 可选择继承全局、强制确认或关闭确认，多行粘贴弹窗会提示一次提交多条命令的风险，识别到 MuseTerm 远端 SSH 命令追踪初始化脚本时会改用专门文案说明临时 shell hook 的用途、边界和失效条件；终端右键菜单可将选中文本转义后作为路径参数填入命令行，普通文件名会单引号转义，已有 `$'...'` / 反斜杠转义形式会原样保留，菜单项保持可点击并在无可用选区时给出系统反馈；右键选区菜单还可复制脱敏文本、Markdown 代码块、AI 解释提示词，识别 URL、路径、明确端口、PID、Git hash、JSON 和常见编码转换，并且端口、PID、Git、路径等排查动作只填入命令等待用户确认；裸数字优先作为 PID 处理，`:3000` 或 `localhost:3000` 等明确端口才展示端口动作，`Foo.swift:42` 等常见文件行号不会误触发端口动作，带 `http://` 或 `https://` 但端口无效的文本不会落入路径菜单；路径子菜单会避开普通短句和语义化版本号等低可信选区，本机路径可在 Finder 中显示，简单单引号和反斜杠转义路径会先静态还原以便识别已存在目录和 `cd` 动作，ANSI-C `$'...'` 不做 shell eval；删除类 `rm -i --` 动作也只填入终端输入区；`rg` 搜索填入动作只面向普通短单行文本，URL、明确端口、PID、Git hash、JSON 和过长单行选区会交给各自上下文动作；Base64 解码动作会过滤短文本、非法 padding 和不可打印结果，避免普通日志片段误触转换入口；高危命令支持内置规则和自定义文本/正则规则，命中规则时会在写入 PTY 前展示预览，取消则不会执行；命令搜索面板会提示疑似敏感输出，并在脱敏开启时对展示、复制、导出和 AI 上下文使用脱敏内容。
- 标签标题：本机会话优先显示当前目录，远端/SSH 标题保留 `user@host` 便于识别。
- App 图标：默认使用 Q 版企鹅终端图标，并支持在设置中切换多款动物头像 Dock 图标。
- CLI/MCP 工具桥：支持安装 `museterm` CLI，供本机 AI 工具读取标签页屏幕、历史文本、最近命令块并发送文本或控制键；状态快照、命令诊断快照以及 `tabs` / `commands` / MCP `read_commands` 输出会暴露 `schemaVersion`，状态快照还会带单调递增的 `snapshotSequence` 和标签 `shellName`，并透传到 CLI/MCP 元数据响应，输入/按键请求响应也会返回契约版本、App 版本、快照序列号、action 和成功目标 tab；命令诊断快照会提供最近失败命令、最近失败退出码、最近失败耗时、最近失败命令来源、最近失败完成来源、连续失败窗口全部命令块 ID、唯一命令、唯一工作目录、上下文变化标记、稳定性枚举与变化原因、平均失败间隔、最近失败间隔、失败节奏分类、首次/最近命令文本、命令 ID、工作目录和输出证据行、0-100 的 `diagnosticPriorityScore` 和稳定 reason code 组成的 `diagnosticPriorityFactors`，方便外部工具按排查优先级排序并解释分数来源；`museterm input --json` 与 `museterm key --json` 可输出完整 response 元数据，`--timeout SECONDS` 可调整等待 App response 的时间，默认短消息输出保持兼容；MCP `send_text` / `send_key` 也支持 `timeout` 和 `metadata`，默认短消息兼容，`metadata: true` 时返回完整 response 元数据；MCP `list_tabs metadata:true` 也会返回 `schemaVersion`、App 名称、版本、选中标签 ID 和带 `shellName` 的标签数组；`screen --json`、`history --json`、`commands`、MCP `read_screen metadata:true`、`read_history metadata:true` 与 `read_commands` 顶层 payload 会带 App 名称、版本、`shellName`、`currentDirectory`、选中标签 ID、标签来源、命令总数、返回命令数、输出尾部截断上限、建议动作执行目标、建议动作结果适用范围、建议动作结果新鲜度策略、建议动作结果复用键字段、建议动作结果复用策略、建议动作结果复用验证检查、建议动作证据锚点、建议动作作用域、建议动作预期结果类型、建议动作预期结果字段、建议动作预期结果信号、建议动作结果解析提示、建议动作结果解释提示、建议动作结果决策提示、建议动作结果局限提示、建议动作敏感结果字段、建议动作结果脱敏提示、建议动作结果刷新触发条件、建议动作结果隐私级别、建议动作结果分享策略、建议动作结果保留策略、建议动作重试条件、建议动作执行前检查、建议动作自动化护栏、建议动作用户决策点、建议动作完成判据和每个命令块的输出尾部截断状态，方便外部工具按 JSON 契约版本兼容处理并判断轮询时是否读到新快照。
- AI Provider 设置：设置页支持 OpenAI、Anthropic、Google Gemini、Azure OpenAI、OpenRouter、Ollama 和自定义端点；API Key 仅保存到本机 Keychain。
- 皮肤系统：从 MuseMail 的视觉体系迁移，针对终端场景提供浅色与深色皮肤。
- 字符配色：支持 Apple、Tango、Solarized、Dracula、One Dark、Nord 等经典 ANSI palette。
- 毛玻璃配置：支持启用/关闭、材质选择、玻璃强度、终端底色透明度、染色和柔光。
- 字体配置：支持从已安装字体中搜索选择主字体和回退字体。
- 排版配置：支持字号和行高调节。
- 光标配置：支持区块 / 竖线 / 下划线三种样式，并可单独开关闪烁。
- 设置窗口：支持 `Cmd+,` 快捷键，并按外观、图标、字体、毛玻璃、行为、AI 和 MCP 工具分组；命令搜索面板可通过侧栏按钮或 `Cmd+F` 打开，任务与端口面板可通过侧栏按钮或 `Cmd+Shift+P` 打开。
- 紧凑侧栏：底部仅保留设置图标入口，减少常驻控件占用。

## 技术栈

- 应用：SwiftUI + AppKit
- 终端内核：SwiftTerm
- 平台：macOS 13.0 及以上（覆盖 macOS 13.7）
- 本地化：`Localizable.strings`
- Runbook 导出：`RunbookMarkdownExporter.swift` 独立负责 Markdown 生成、诊断摘要写入、回放脚本生成、路径变量参数化和回放确认包装。
- 敏感信息脱敏：`RunbookSensitiveRedactor.swift` 独立负责 Runbook、AI 上下文、命令搜索展示和诊断摘要里的 token、API Key、URL 凭据与私钥块脱敏。
- AI Explain 客户端：`AIExplainClient.swift` 独立负责 Provider 配置校验、OpenAI/Anthropic/Gemini 兼容流式请求、SSE 增量解析和错误映射，让主视图文件保持在 2000 行以下。
- 安全输入分析：`TerminalSafetyInputAnalyzer.swift` 独立承载多行粘贴识别、高危命令规则、自定义文本/正则规则解析和确认预览控件，让终端宿主视图保持在 2000 行以下。
- 诊断契约：`CommandDiagnosticAction.swift` 独立承载结构化建议排查动作和稳定 action code，`LocalServiceScanner.swift` 独立负责本机监听端口扫描、`lsof` 字段解析、服务名识别和端口搜索匹配模型，`TaskPortPanel.swift` 保留面板、统计与诊断生成逻辑。
- 统计持久化：`PersistentCommandStatsStore.swift` 独立负责每日命令统计的本地 JSON 读写，让任务与端口面板文件保持在 2000 行以下。

## 运行

- 打开 `museterm.xcodeproj`
- 选择 `museterm` scheme
- 在 Xcode 中运行

## API 概览

本项目当前没有网络服务端 API。CLI/MCP 通过本机 `~/Library/Application Support/MuseTerm/Tools` 目录交换状态与输入请求，状态包含标签页屏幕、历史文本、最近结构化命令块、命令诊断摘要和标签 `shellName`，并在顶层暴露 `schemaVersion` 与单调递增的 `snapshotSequence`；`museterm tabs`、`museterm commands` 和 MCP `read_commands` 响应也会透传顶层 `schemaVersion` 与 `snapshotSequence`，MCP `list_tabs` 默认继续返回标签数组，传入 `metadata: true` 时会返回包含 `schemaVersion`、`snapshotSequence`、App 名称、版本、选中标签 ID 和带 `shellName` 标签数组的对象，外部工具无需读取原始状态文件即可判断契约版本、shell 环境和轮询时是否读到新快照；输入/按键请求的 response 文件会返回 `schemaVersion`、App 名称、版本、`snapshotSequence`、`action` 和成功目标 `tabID`，便于外部工具定位请求处理环境，`museterm input --json` 与 `museterm key --json` 可直接输出这份完整响应，`--timeout SECONDS` 可调整等待 App response 文件的时长；MCP `send_text` / `send_key` 支持 `timeout` 和 `metadata` 参数，默认返回短消息，`metadata: true` 时返回完整 response 元数据；`museterm screen --json`、`museterm history --json` 以及 MCP `read_screen` / `read_history` 的 `metadata: true` 会返回 App 名称、版本、标签 `shellName`、`selectedTabID`、文本、字符数、返回字符数、截断上限和截断状态，默认纯文本输出保持兼容；命令块包含开始来源、完成来源和紧凑输出摘要，便于外部工具判断命令边界来自 shell hook 还是输入推断、退出码来自 shell hook 还是进程退出兜底，并直接读取错误、URL、路径和 commit 等关键线索；命令块读取响应会在顶层返回 App 名称、版本、`tabID`、`shellName`、`selectedTabID`、`commandCount`、`returnedCommandCount` 和数字或 `null` 类型的 `outputTailLimit`；命令块输出元数据会区分 App 内部保存的 `outputTail` 是否已相对完整输出截断，以及 `--chars` / MCP `chars` 是否又对返回 tail 做了二次限制：字段包含 `outputTailCharacters`、`outputTailReturnedCharacters`、数字或 `null` 类型的 `outputTailLimit`、`outputTailTruncated` 和 `outputTailStoredTruncated`；命令诊断摘要包含自己的 `schemaVersion`、失败命令数、诊断优先级分数、诊断优先级因素、诊断严重级别、诊断分类、诊断分类依据、诊断分类可信度、最近失败命令、最近失败诊断、失败指纹、连续同类失败、匹配方式、连续失败时间窗、持续时长、平均失败间隔、最近失败间隔、失败节奏分类、建议下一步查看项、建议排查命令和结构化建议排查动作；建议动作包含稳定 `id`、来源诊断分类、动作可信度、动作优先级分数、动作优先级因素、证据锚点、作用域、预期结果类型、预期结果字段、预期结果信号、结果解析提示、结果解释提示、结果决策提示、结果局限提示、敏感结果字段、结果脱敏提示、结果刷新触发条件、结果隐私级别、结果分享策略、结果保留策略、结果适用范围、结果新鲜度策略、结果复用键字段、结果复用策略、结果复用验证检查、执行模式、执行目标、重试条件、执行前检查、自动化护栏、用户决策点、完成判据、标题、原因、命令、执行后观察信号、观察不到预期信号时的降级步骤、安全级别和确认要求，`executionMode` 当前为 `stage_only`，外部工具只能填入或展示建议动作，执行仍必须由用户确认；`actionScope` 会描述建议动作主要检查本地网络、权限边界、shell 环境、工作目录、Git 仓库、连续失败上下文或当前会话；`expectedResultKind` 会描述建议命令预期返回监听端口列表、身份与权限信息、PATH、目录列表、Git 状态或上下文快照；`expectedResultFields` 会描述建议命令输出中应重点抽取端口、PID、进程名、当前用户、目录权限、PATH 条目、Git 分支、upstream 和 dirty 状态等字段；`expectedResultSignals` 会描述哪些输出信号代表只读检查已经拿到可用证据；`resultParsingHints` 会描述建议命令输出应如何解析，例如按行文本、空白分隔列、PATH 列表、组合命令输出、目录列表、Git porcelain 状态或可选 Git 输出；`resultInterpretationHints` 会描述建议命令输出应如何解释，例如空端口列表表示本机无监听者、权限输出需要比较用户与权限位、Git dirty 状态需要用户决策；`resultDecisionHints` 会描述建议命令结果应触发的保守决策分支，例如端口 owner 需要用户决定、权限不匹配需要明确提权、缺失 PATH 条目可能需要激活环境或安装、Git dirty 状态需要先处理工作树；`resultCaveats` 会描述建议命令结果的适用局限，例如本机端口扫描只覆盖当前网络命名空间、PATH 只代表当前 shell、Git status 需要位于仓库内；`sensitiveResultFields` 会描述建议命令结果中哪些字段可能携带路径、用户、进程、Git 或目录元数据等敏感上下文；`resultPrivacyLevel` 会汇总建议命令结果的隐私敏感级别；`resultSharingPolicy` 会声明建议命令结果应直接分享、先脱敏再分享，还是仅本地查看；`resultFreshnessPolicy` 会声明建议命令结果是实时快照、上下文绑定，还是仅对当前失败尝试有效；`resultReuseKeyFields` 会声明复用建议命令结果前应比较的上下文字段，例如终端会话、工作目录、Shell 环境、Git 仓库、监听端口、权限元数据或失败指纹；`resultReusePolicy` 会声明历史建议命令结果应先刷新再用、仅在复用键匹配时可用，还是不能跨失败尝试复用；`resultReuseValidationChecks` 会描述复用历史建议命令结果前应完成的机器可读检查，例如刷新动态快照、匹配工作目录、Shell 环境、用户身份、Git 状态或失败指纹；`executionTarget` 会描述建议命令应在当前终端会话、当前工作目录、当前 shell 环境、当前 Git 仓库或当前终端网络命名空间中理解；`retryCondition` 会描述用户考虑重跑失败命令前应满足的条件；`preflightChecks` 会描述填入建议动作前应确认的上下文；`automationGuardrails` 会描述建议动作不能自动越过的边界；`userDecisionPoints` 会描述哪些判断必须交给用户拍板；`completionCriteria` 会描述这一轮排查何时可以收口；`evidenceAnchors` 会用稳定 code 标明建议动作锚定的诊断证据来源；`museterm commands` 和 MCP `read_commands` 会返回 `diagnostics` + `commands` 的 JSON 对象。CLI 支持 `tabs`、`screen`、`history`、`commands`、`input`、`key` 和 `mcp`。任务与端口面板通过系统 `lsof` 读取本机监听 TCP 端口，只展示并填入命令，不会直接结束进程；当前会话进程工具同样只向选中终端填入命令，是否执行由用户按回车确认。录制捷径保存在 `~/Library/Application Support/MuseTerm/TerminalShortcuts/shortcuts.json`，工作区快照保存在 `~/Library/Application Support/MuseTerm/Workspaces/last-workspace.json`，每日命令统计保存在 `~/Library/Application Support/MuseTerm/Stats/daily-command-stats.json`，SSH profile 与 AI Provider 非敏感配置保存在用户偏好中，AI API Key 通过 Keychain 保存，仅在 AI Explain 请求时进入对应 Provider 的请求 header 或 query，不写入 MCP 状态；命令搜索面板的脱敏开关会在 Runbook、AI 上下文和 AI Explain 请求中替换常见 token/password/API Key 形态，Runbook 与 AI 当前过滤上下文还会带上最近失败、失败指纹、连续同类失败摘要、匹配方式、连续失败时间窗、持续时长、平均失败间隔、最近失败间隔、失败节奏分类、建议排查命令、结构化建议排查动作、稳定动作 ID、动作来源分类与可信度、动作优先级分数与因素、动作证据锚点、动作作用域、动作预期结果类型、动作预期结果字段、动作预期结果信号、动作结果解析提示、动作结果解释提示、动作结果决策提示、动作结果局限提示、动作敏感结果字段、动作结果脱敏提示、动作结果刷新触发条件、动作结果隐私级别、动作结果分享策略、动作结果保留策略、动作结果适用范围、动作结果新鲜度策略、动作结果复用键字段、动作结果复用策略、动作结果复用验证检查、动作执行模式、动作执行目标、动作重试条件、动作执行前检查、动作自动化护栏、动作用户决策点、动作完成判据、动作观察信号、动作降级步骤、诊断分类、诊断分类依据、诊断分类可信度、诊断严重级别、诊断优先级分数和诊断优先级因素；运行时 SSH config 生成到 `~/Library/Application Support/MuseTerm/SSH`，本地 zsh/bash/fish shell integration 生成到 `~/Library/Application Support/MuseTerm/ShellIntegration`，远端 shell hook 仅在当前 SSH 会话内临时生效。版本号通过应用内 `AppVersion` 和 Xcode `MARKETING_VERSION` 保持一致，发布最低系统版本通过 Xcode `MACOSX_DEPLOYMENT_TARGET` 管理。

`latestFailedCommandID`、`latestFailedWorkingDirectory`、`recentFailureCommandID` 与 `recentFailureWorkingDirectory` 会在 Runbook、AI 当前过滤上下文和 CLI/MCP `commandDiagnostics` 中暴露最近失败命令与最近失败诊断对应的结构化命令块 ID 和工作目录；建议动作的 `evidenceAnchors` 也会包含 `latest_failed_command_id`、`recent_failure_command_id` 与 `recent_failure_working_directory`，方便外部工具从诊断结果跳回原始 `commands` 数组中的命令块，并确认失败发生在哪个项目上下文。

`repeatedFailureDiagnostic.commandIDs`、`uniqueCommands`、`uniqueWorkingDirectories`、`contextChanged`、`contextStability`、`contextChangeReasons`、`averageIntervalMilliseconds`、`latestIntervalMilliseconds`、`cadence`、`firstCommandID`、`latestCommandID`、`firstCommand`、`latestCommand`、`firstWorkingDirectory`、`latestWorkingDirectory`、`firstOutputTailLineNumber`、`firstOutputTailLineText`、`latestOutputTailLineNumber` 与 `latestOutputTailLineText` 会在 Runbook、AI 当前过滤上下文和 CLI/MCP `commandDiagnostics` 中暴露连续同类失败窗口的完整命令块 ID 列表、唯一命令、唯一工作目录、上下文变化标记、稳定性枚举、稳定变化原因 code、平均失败间隔、最近失败间隔、失败节奏分类，以及窗口两端的结构化命令块 ID、命令文本、工作目录和输出证据行，方便外部工具判断重复失败期间是否已经换过命令或目录，并直接定位两端原始输出；`latestIntervalMilliseconds` 用于判断最近两次失败是否又短间隔重试，`cadence` 使用 `immediate_retry`、`rapid_retry` 或 `spaced_retry` 概括重复失败节奏，命令文本沿用敏感信息脱敏策略。

`latestFailedExitCode`、`latestFailedDurationMilliseconds`、`latestFailedCommandStartSource` 与 `latestFailedCompletionSource` 会在 Runbook、AI 当前过滤上下文和 CLI/MCP `commandDiagnostics` 中暴露最近失败命令的退出码、耗时、开始来源与完成来源；CLI/MCP JSON 使用数字、字符串或 `null`，方便外部工具直接判断失败类型、区分快速失败和慢失败，并识别命令边界来自 shell integration 还是用户输入推断、退出码来自 shell integration、进程退出兜底、用户中断还是覆盖结束，而不必重新解析命令块列表。

`resultRetentionPolicy` 会声明建议命令结果可完整保存、只能保存脱敏摘要，还是仅保留在本机会话；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，供外部工具在记录日志或建立索引前选择保留边界。

`resultRedactionHints` 会提示建议命令结果中应优先脱敏的内容类型，例如路径、用户、进程、监听地址、Git 分支和 upstream；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，供外部工具在摘要、分享或持久化前选择更准确的脱敏策略。

`resultRefreshTriggers` 会声明哪些上下文变化会让建议命令结果过期，例如进程、监听端口、工作目录、权限、PATH、文件系统或 Git 状态变化；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，供外部工具在重用旧诊断结果前判断是否需要重新取证。

`resultInterpretationHints` 会描述建议命令输出应如何解释，例如空端口列表表示本机无监听者、权限输出需要比较用户与权限位、Git dirty 状态需要用户决策；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，帮助外部工具少依赖自然语言猜测排查结果含义。

`resultDecisionHints` 会描述建议命令结果应触发的保守决策分支，例如端口 owner 需要用户决定、权限不匹配需要明确提权、缺失 PATH 条目可能需要激活环境或安装、Git dirty 状态需要先处理工作树；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，让外部工具在解析和解释输出后仍保持“只建议、不越权”的执行边界。

`resultCaveats` 会描述建议命令结果的适用局限，例如本机端口扫描只覆盖当前网络命名空间、PATH 只代表当前 shell、Git status 需要位于仓库内；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，帮助外部工具避免把只读检查结果过度推广到容器、远端、其他 shell 或后续已变化的上下文。

`resultParsingHints` 会描述建议命令输出应如何解析，例如按行文本、空白分隔列、PATH 列表、组合命令输出、目录列表、Git porcelain 状态或可选 Git 输出；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，帮助外部工具先稳定拆解输出，再应用解释、脱敏和复用策略。

`resultValidityScope` 会声明建议命令结果可在哪个范围内复用，例如当前终端会话、网络命名空间、工作目录、Shell 环境或 Git 仓库；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，帮助外部工具避免把本地、远端、目录或仓库上下文混用。

`resultFreshnessPolicy` 会声明建议命令结果是实时快照、上下文绑定，还是仅对当前失败尝试有效；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，帮助外部工具在复用历史诊断结果前判断是否必须重新取证。

`resultReuseKeyFields` 会声明复用建议命令结果前应比较的上下文字段，例如终端会话、工作目录、Shell 环境、Git 仓库、监听端口、权限元数据或失败指纹；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，帮助外部工具避免把不同目录、环境、仓库或失败场景的历史诊断结果混用。

`resultReusePolicy` 会声明历史建议命令结果应先刷新再用、仅在复用键匹配时可用，还是不能跨失败尝试复用；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，帮助外部工具在读取历史诊断结果时选择刷新、保守复用或重新取证。

`resultReuseValidationChecks` 会描述复用历史建议命令结果前应完成的机器可读检查，例如刷新动态快照、匹配工作目录、Shell 环境、用户身份、Git 状态或失败指纹；Runbook、AI 上下文和 CLI/MCP `commandDiagnostics.suggestedNextAction` 会同步暴露该字段，让外部工具在复用历史诊断前有明确的验证清单。

## 已知问题 / 待办

- [ ] 增加终端配色 palette 的完整 16/256 色映射。
- [ ] 增加标签重命名、手动选择新标签启动目录和自定义启动命令。
- [ ] 为远端 fish 与更复杂的 nested shell/tmux 场景增强 shell integration 准确性。
- [ ] 为 SSH profile 增加导入 `~/.ssh/config` 和分组搜索。
