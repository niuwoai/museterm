# MuseTerm Feature Roadmap

> 最后更新：2026-06-30  
> 当前版本基线：v1.8.1-rc1  
> 文档状态：概念规划与可行性评估，不代表已实现功能。

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
- 保存和恢复 SSH 标签所使用的 profile ID。
- 先不恢复滚屏内容，不自动重放历史命令。
- 提供“保存当前工作区”和“打开工作区”入口。

### 技术可行性

可行性：中高。

主要工作是数据模型和 UI。恢复本地 shell 较简单；恢复 SSH 需要处理 profile 被删除或修改的情况；恢复命令历史不建议第一版做，容易误导用户以为进程也被恢复。

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

## 推荐实施顺序

1. 建立 `CommandBlock` 数据模型和最小 shell integration。
2. 在当前标签内展示最近命令块与执行摘要。
3. 做当前标签搜索，支持搜索命令和输出片段。
4. 把 command block 暴露给 CLI/MCP。
5. 增加失败命令上下文复制与脱敏。
6. 增加 SSH profile 环境字段与 `PROD` 标识。
7. 增加多行粘贴预览与高危命令确认。
8. 做项目工作区保存与恢复。
9. 再进入任务/端口面板、Runbook、统计娱乐功能。

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
