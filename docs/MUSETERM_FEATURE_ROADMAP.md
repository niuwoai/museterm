# MuseTerm Feature Roadmap

> 最后更新：2026-07-01
> 当前版本基线：v1.46.0
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

v1.46.0 已完成三十八条纵向切片：

- AI Provider 设置：已支持常见 Provider 与自定义端点，API Key 保存到本机 Keychain。
- 结构化命令块基础采集：已记录用户提交命令、工作目录、时间、输出尾部、输出字符数和中断/进程退出状态。
- 命令块完成来源：已记录命令结束来源，区分 shell integration 真实退出码、进程退出兜底、用户中断、被下一条命令覆盖和未知来源，并同步给搜索、AI 上下文与 CLI/MCP 快照。
- 命令块开始来源：本地 zsh/fish 与远端 zsh 已通过 shell marker 回传命令开始和命令文本，命令块会记录开始来源；bash 仍保守使用用户输入推断开始、shell hook 回传结束码。
- 命令块输出摘要：已把输出洞察沉入结构化命令块，记录洞察类型、首个错误/警告、URL、文件路径、commit hash 和堆栈线索，并同步给搜索、AI 上下文与 CLI/MCP 快照。
- Runbook 输出摘要：导出的 Markdown 会消费命令块里的紧凑输出摘要，把关键错误、URL、路径、commit 与堆栈线索写成独立段落，并沿用现有敏感信息脱敏开关。
- 失败诊断展示：命令搜索卡片已优先使用结构化输出摘要展示洞察标签；失败命令会直接露出首条关键诊断行，让错误原因不必埋在输出尾部里。
- 最近失败统计：任务与端口面板的本次会话统计已展示最近失败诊断行，并在统计模型层统一脱敏，让“失败了几次”进一步变成“最近卡在哪”。
- 连续失败提醒：统计面板会在最近连续 3 次以上同一诊断失败时显示重复提醒；最新命令成功或诊断变化时不提示，保持克制。
- 诊断摘要复用：Runbook 导出与 AI Explain 当前过滤上下文会复用同一套 `CommandBlockDiagnostics`，记录最近失败和连续同类失败摘要，并沿用脱敏策略。
- CLI/MCP 诊断摘要：工具状态文件为每个 tab 增加 `commandDiagnostics`，`museterm commands` 与 MCP `read_commands` 返回 `diagnostics` + `commands`，外部工具可直接读取最近失败和连续同类失败线索。
- 诊断摘要可操作化：`CommandBlockDiagnostics` 新增失败命令数、最近失败命令和建议下一步查看项，并同步进入 Runbook、AI 当前过滤上下文与 CLI/MCP `diagnostics`。
- 诊断严重级别：`CommandBlockDiagnostics` 新增 `diagnosticSeverity`，将 none/failed/repeated/critical 暴露到 Runbook、AI 上下文和 CLI/MCP `diagnostics`，帮助外部工具先判断排查优先级。
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
- 安全模式自定义规则：行为设置中已支持自定义高危命令规则，每行一条，普通文本按包含匹配，`regex:` 前缀按正则匹配，命中后会显示具体规则并要求确认。
- 安全模式按 profile 覆盖：SSH profile 已支持安全确认策略，可继承全局、强制确认或关闭确认；生产环境默认强制确认。
- 敏感输出脱敏提示：命令搜索面板会提示疑似敏感输出数量，命令卡片显示警示；脱敏开启时展示、复制、导出和 AI 上下文均使用脱敏内容。
- Runbook 导出与回放第一版：命令搜索面板可将当前过滤结果导出为 Markdown，支持备注、敏感信息脱敏、回放脚本、复制到剪贴板和保存 `.md` 文件；单条命令可填入当前终端待执行，但不会自动回车。
- 任务与端口面板第一版：右侧面板可查看运行中的结构化命令块和本机监听 TCP 端口，支持刷新、打开 `localhost` URL、复制监听地址，并将 `kill PID` 填入当前终端等待用户确认。
- 项目工作区恢复第一版：标签菜单可保存当前本地/SSH 标签、选中标签和本地目录，并可确认后从上次快照恢复；本地 shell 会直接启动到保存目录，SSH 标签恢复连接入口，运行中进程不做冻结恢复。
- Runbook 回放安全增强：回放脚本可将本机 Home 与工作目录参数化为 `RUNBOOK_HOME` / `RUNBOOK_WORKDIR`，并默认用 `run_step` 逐条确认后再执行命令。
- Runbook 变量编辑体验：命令搜索面板可编辑 `RUNBOOK_HOME` 与 `RUNBOOK_WORKDIR` 默认值，复制回放、复制 Runbook 和保存 Markdown 共用同一套变量覆盖值。
- AI Explain 上下文选择：命令搜索面板可在只发命令、当前命令块、当前过滤结果摘要之间切换上下文范围，复制 AI 上下文和直接解释共用同一设置。
- 统计娱乐系统第一版：任务与端口面板显示本次会话命令数、失败数、运行中命令、端口数、最长耗时和轻量成就徽章。
- 统计持久化第一版：任务与端口面板显示“今天”统计，跨 App 重启累计当天已结束命令数、失败数和最长命令耗时。
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
