# Product Overview

> 最后更新：2026-07-01 | 当前版本：v1.60.0

## 项目简介

MuseTerm 是一个轻快的 macOS 多标签终端应用，使用 SwiftUI 构建外壳界面，并通过 SwiftTerm 提供本地 shell 终端能力。

## 核心功能

- 多标签终端：左侧纵向标签列表，支持新建、切换、关闭标签；关闭按钮仅在鼠标悬停到整块标签行时显示，并可通过侧栏图标或设置开关折叠列表。
- 标签快捷键：支持 `Cmd+T` 新建、`Cmd+W` 关闭当前标签（关掉最后一个标签即关闭窗口，所有窗口关闭后退出 App）、`Cmd+Shift+[` / `Cmd+Shift+]` 前后切换，以及 `Cmd+1` 到 `Cmd+9` 直达标签；标签标题后用浅色 `⌘N` 标注对应快捷键。
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
- Shell integration：本地 zsh 和 fish 会加载 MuseTerm 专用 preexec/postexec hook 以回传命令开始和真实退出码，本地 bash 通过生成 rcfile 挂载 `PROMPT_COMMAND` 回传退出码；SSH profile 可为远端 zsh 回传命令开始和退出码，为远端 bash 回传退出码，不写入远端启动文件；其他 shell 暂时使用保守识别。
- 命令搜索面板：右侧检查面板可搜索当前标签的命令、目录、命令块输出和原始滚屏历史，支持仅看失败命令；命令块会轻量识别错误、警告、URL、文件路径、JSON/YAML、堆栈和 commit hash，失败命令卡片会直接展示首条关键诊断行，并可复制命令、输出尾部、输出摘要、滚屏片段或 AI 上下文；JSON 输出摘要会自动带上格式化后的 pretty JSON。
- 任务与端口面板：右侧面板可查看运行中的结构化命令块和本机监听 TCP 端口，支持刷新、打开 `localhost` URL、复制监听地址，并可将本机 `kill PID` 填入本地终端等待确认执行；当前会话工具可向本地或 SSH 标签填入端口扫描、进程列表、PID 详情、SIGTERM 和 SIGKILL 命令；面板还展示本次会话命令统计、当天跨重启累计统计、最长耗时、最近失败诊断、连续同类失败提醒和轻量成就徽章。
- AI Explain：命令搜索面板可直接对单条命令块请求 AI 解释，覆盖命令意图、输出状态、失败原因、风险点和下一步建议，并在 Provider 返回内容时流式增量显示；AI 上下文可选择只发命令、当前命令块或当前过滤结果摘要；支持 OpenAI 兼容接口、Anthropic、Google Gemini、Azure OpenAI、OpenRouter、Ollama 和自定义端点。
- Runbook 导出与回放：命令搜索面板可把当前过滤出的命令块生成 Markdown，支持备注、敏感信息脱敏、输出摘要、失败诊断、诊断分类、分类依据与可信度、连续同类失败摘要、建议排查命令、结构化建议排查动作、稳定动作 ID、动作来源分类与可信度、动作观察信号、动作降级步骤、回放脚本、复制到剪贴板和保存为 `.md` 文件；回放脚本可参数化本机路径，并可编辑 `RUNBOOK_HOME` / `RUNBOOK_WORKDIR` 默认值，默认对每条命令逐步确认；单条命令可填入当前终端待执行，但不会自动回车；Runbook 会记录疑似敏感输出数量、脱敏状态、参数化状态、变量默认值、逐步确认状态，以及每条命令的错误/警告、URL、路径、commit 和堆栈线索。
- 安全确认：可在设置中开启/关闭多行粘贴确认和高危命令确认；SSH profile 可选择继承全局、强制确认或关闭确认，高危命令支持内置规则和自定义文本/正则规则，命中规则时会在写入 PTY 前展示预览，取消则不会执行；命令搜索面板会提示疑似敏感输出，并在脱敏开启时对展示、复制、导出和 AI 上下文使用脱敏内容。
- 标签标题：本机会话优先显示当前目录，远端/SSH 标题保留 `user@host` 便于识别。
- App 图标：默认使用 Q 版企鹅终端图标，并支持在设置中切换多款动物头像 Dock 图标。
- CLI/MCP 工具桥：支持安装 `museterm` CLI，供本机 AI 工具读取标签页屏幕、历史文本、最近命令块并发送文本或控制键；状态快照、命令诊断快照以及 `tabs` / `commands` / MCP `read_commands` 输出会暴露 `schemaVersion`，`commands` / `read_commands` 的命令块还会标明输出尾部长度、截断上限和是否截断，方便外部工具按 JSON 契约版本兼容处理。
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

## 运行

- 打开 `museterm.xcodeproj`
- 选择 `museterm` scheme
- 在 Xcode 中运行

## API 概览

本项目当前没有网络服务端 API。CLI/MCP 通过本机 `~/Library/Application Support/MuseTerm/Tools` 目录交换状态与输入请求，状态包含标签页屏幕、历史文本、最近结构化命令块和命令诊断摘要，并在顶层暴露 `schemaVersion`；`museterm tabs`、`museterm commands` 和 MCP `read_commands` 响应也会透传顶层 `schemaVersion`，外部工具无需读取原始状态文件即可判断契约版本；`museterm screen --json`、`museterm history --json` 以及 MCP `read_screen` / `read_history` 的 `metadata: true` 会返回文本、字符数、返回字符数、截断上限和截断状态，默认纯文本输出保持兼容；命令块包含开始来源、完成来源和紧凑输出摘要，便于外部工具判断命令边界来自 shell hook 还是输入推断、退出码来自 shell hook 还是进程退出兜底，并直接读取错误、URL、路径和 commit 等关键线索；命令块输出元数据会区分 App 内部保存的 `outputTail` 是否已相对完整输出截断，以及 `--chars` / MCP `chars` 是否又对返回 tail 做了二次限制：字段包含 `outputTailCharacters`、`outputTailReturnedCharacters`、数字或 `null` 类型的 `outputTailLimit`、`outputTailTruncated` 和 `outputTailStoredTruncated`；命令诊断摘要包含自己的 `schemaVersion`、失败命令数、诊断严重级别、诊断分类、诊断分类依据、诊断分类可信度、最近失败命令、最近失败诊断、失败指纹、连续同类失败、匹配方式、连续失败时间窗、持续时长、建议下一步查看项、建议排查命令和结构化建议排查动作；建议动作包含稳定 `id`、来源诊断分类、动作可信度、标题、原因、命令、执行后观察信号、观察不到预期信号时的降级步骤、安全级别和确认要求，`museterm commands` 和 MCP `read_commands` 会返回 `diagnostics` + `commands` 的 JSON 对象。CLI 支持 `tabs`、`screen`、`history`、`commands`、`input`、`key` 和 `mcp`。任务与端口面板通过系统 `lsof` 读取本机监听 TCP 端口，只展示并填入命令，不会直接结束进程；当前会话进程工具同样只向选中终端填入命令，是否执行由用户按回车确认。录制捷径保存在 `~/Library/Application Support/MuseTerm/TerminalShortcuts/shortcuts.json`，工作区快照保存在 `~/Library/Application Support/MuseTerm/Workspaces/last-workspace.json`，每日命令统计保存在 `~/Library/Application Support/MuseTerm/Stats/daily-command-stats.json`，SSH profile 与 AI Provider 非敏感配置保存在用户偏好中，AI API Key 通过 Keychain 保存，仅在 AI Explain 请求时进入对应 Provider 的请求 header 或 query，不写入 MCP 状态；命令搜索面板的脱敏开关会在 Runbook、AI 上下文和 AI Explain 请求中替换常见 token/password/API Key 形态，Runbook 与 AI 当前过滤上下文还会带上最近失败、失败指纹、连续同类失败摘要、匹配方式、连续失败时间窗、持续时长、建议排查命令、结构化建议排查动作、稳定动作 ID、动作来源分类与可信度、动作观察信号、动作降级步骤、诊断分类、诊断分类依据、诊断分类可信度和诊断严重级别；运行时 SSH config 生成到 `~/Library/Application Support/MuseTerm/SSH`，本地 zsh/bash/fish shell integration 生成到 `~/Library/Application Support/MuseTerm/ShellIntegration`，远端 shell hook 仅在当前 SSH 会话内临时生效。版本号通过应用内 `AppVersion` 和 Xcode `MARKETING_VERSION` 保持一致，发布最低系统版本通过 Xcode `MACOSX_DEPLOYMENT_TARGET` 管理。

## 已知问题 / 待办

- [ ] 增加终端配色 palette 的完整 16/256 色映射。
- [ ] 增加标签重命名、手动选择新标签启动目录和自定义启动命令。
- [ ] 为远端 fish 与更复杂的 nested shell/tmux 场景增强 shell integration 准确性。
- [ ] 为 SSH profile 增加导入 `~/.ssh/config` 和分组搜索。
