# QTerm AppleScript 支持需求文档

> 版本：v1.225.0-rc2 | 最后更新：2026-07-11
> 状态：P1 / P2 / P3 全量实现

## 1. 背景与目标

macOS 上专业终端的隐形门槛之一是 AppleScript 可脚本化：iTerm2 的词典支撑了大量自动化工作流，系统 Terminal 也提供 `do script`。QTerm 已有 CLI、MCP、Tool Bridge 三套自动化入口，核心动作面（读屏、历史、命令块、输入、按键）均已存在。本需求为同一内核增加第四个门面 —— Cocoa Scripting（AppleScript / JXA / Shortcuts「运行 AppleScript」均可调用），不重写业务逻辑。

**目标用户场景：**

- 自动化脚本：`osascript` / Automator / Shortcuts / Keyboard Maestro / Alfred 等工具驱动终端。
- 巡检与监控：读取标签状态、最近命令的退出码，失败时告警。
- 工作流编排：新建标签、打开 SSH 收藏、批量下发命令并同步等待结果。

## 2. 术语与对象模型（sdef）

应用以 `tell application "QTerm"` 寻址。对象模型为扁平两层：

| 对象 | 属性 | 说明 |
|------|------|------|
| `application` | `selected tab`（可读写）、`scripted input allowed`（只读） | 顶层容器，`tabs` 为其元素 |
| `tab` | `id`、`index`、`title`、`current directory`、`busy`、`state`、`selected`（可读写）、`contents`（当前屏幕文本）、`history`（滚动历史尾部）、`columns`、`rows`、`shell` | 终端标签；`command records` 为其元素 |
| `command record` | `command`、`exit code`、`running`、`output`、`duration`（秒）、`working directory`、`started at`、`ended at` | 由 shell integration 产生的结构化命令块（最近 50 条），**iTerm2 与 Terminal.app 均不提供** |

## 3. 命令（动词）

### P1 — 基础读写

| 命令 | 语法示例 | 说明 |
|------|----------|------|
| `create tab` | `create tab in directory "~/Sites"` | 新建本地标签，返回 tab 对象；目录可省略 |
| `close tab` | `close tab 2` | 关闭标签，默认遵循「关闭前确认」偏好；自动化清理可显式传入 `skipping confirmation true` 跳过确认。目标可用 1-based 索引、tab 对象或 tab ID。 |
| `select` | `select tab 2` | 切换选中标签；也可 `set selected tab to tab 2` |
| `write text` | `write text "ls -la" to tab 1` | 写入文本，默认追加回车；`newline false` 可关闭 |
| `send key` | `send key "ctrl-c" to selected tab` | 发送控制键，键名与 CLI 一致（enter/tab/escape/backspace/ctrl-c/ctrl-d/ctrl-z/ctrl-l/up/down/left/right 等） |
| 读属性 | `get contents of selected tab` | 屏幕文本 / 历史 / 目录 / 忙碌状态等 |

### P2 — 同步执行（招牌能力）

```applescript
tell application "QTerm"
  set r to execute "git status" in tab 1 timeout 60
  -- r 为记录：{succeeded:true, exit code:0, output:"...", duration:0.42}
end tell
```

- 依赖 shell integration 的命令边界事件：发送命令后阻塞（挂起 Apple 事件）直至命令块结束，返回退出码、输出尾部与耗时。
- `timeout` 单位秒，默认 120，上限 3600；超时报错并提示可能未启用 shell integration。
- `output` 为命令块的输出尾部（与命令巡检器一致，有长度上限），超长输出请用 `history of tab`。

### P3 — QTerm 特色

| 命令 | 语法示例 | 说明 |
|------|----------|------|
| `open ssh profile` | `open ssh profile "prod-db"` | 按显示名打开 SSH 收藏，返回新 tab |
| `play shortcut` | `play shortcut "deploy" in tab 1` | 回放录制的快捷方式；**含受保护输入（echo-off 密码段）的快捷方式一律拒绝** |
| `command records` | `exit code of last command record of tab 1` | 查询最近命令及退出码 |

## 4. 安全边界（MUST）

1. **写入总开关**：设置 › 工具 新增「允许 AppleScript 写入终端」（默认开启；macOS 本身还有 TCC 自动化授权弹窗把第一道关）。关闭后 `write text` / `send key` / `execute` / `play shortcut` 全部报错，只读能力（属性、命令记录）不受影响。
2. **受保护输入永不外泄**：录制宏中 `requiresEchoOff` 的密码段不通过任何脚本接口回放或读取；`play shortcut` 遇到 `hasProtectedInput == true` 直接报错。
3. 错误一律走 AppleScript 错误通道（自定义错误码 -31000 起），不静默吞掉。

## 5. 实现方案

- `museterm/museterm.sdef`：词典定义；`museterm/Info.plist`（与生成式 Info.plist 合并）声明 `NSAppleScriptEnabled` + `OSAScriptingDefinition`。
- `museterm/MuseTermScripting.swift`：
  - `MuseTermScriptingRegistry`：弱引用桥接 SwiftUI 场景中的 `TerminalWorkspace` / `TerminalPreferences` / `SSHConnectionStore`（在 `ContentView.onAppear` 与 Tool Bridge 一起挂接）。
  - `NSApplication` 扩展提供 `scriptTabs` / `scriptSelectedTab` KVC 键与按 uniqueID 解析。
  - `MuseTermScriptTab` / `MuseTermScriptCommandRecord`：NSObject 包装器（会话本体非 NSObject，不能直接曝光给 Cocoa Scripting），按会话 ID 缓存保证对象标识稳定。
  - 动词为 `NSScriptCommand` 子类；`execute` 用 `suspendExecution` / `resumeExecution(withResult:)` 挂起事件，主线程定时器轮询命令块完成。
  - `close tab` 使用独立命令类解析索引、tab 对象或 ID；`skipping confirmation` 缺省为 `false`，只有显式传 `true` 才绕过运行中标签确认。
  - 动作实现直接复用 Tool Bridge 同款内核：`TerminalWorkspace.sendToolInput`、`TerminalToolInput.bytes(forKey:)`、`TerminalHostController` 的屏幕/历史快照。
- 错误码表：-31000 无工作区、-31001 找不到标签、-31002 写入被禁用、-31003 未知键名、-31004 进程不可用、-31005 找不到 SSH 收藏、-31006 找不到快捷方式、-31007 快捷方式含受保护输入、-31008 执行超时、-31009 空命令、-31010 关闭被取消。

## 6. 测试

- 单元测试（`musetermTests/MuseTermScriptingTests.swift`）：sdef 打包与 XML 合法性、关键术语存在性、偏好默认值与持久化、受保护快捷方式拦截、执行结果记录描述符构造。
- 冒烟测试（`scripts/applescript_smoke_test.rb`，Ruby）：对运行中的 App 依次跑 count tabs / create tab / write text / contents / execute / close，清理阶段使用 `skipping confirmation true`，输出 JSON 与 Markdown 双格式报告。需要终端具备「自动化」TCC 授权。

## 7. 已知限制与后续

- `execute` 依赖 shell integration；未启用时以超时错误提示。
- `output` 为输出尾部截断（与命令巡检器上限一致）。
- 暂不提供 window 层级（QTerm 为单窗口多标签）；如未来支持多窗口需在词典中插入 window 容器层。
- Shortcuts（App Intents）原生动作暂未提供，可作为后续版本目标（词汇表可与本词典对齐）。
