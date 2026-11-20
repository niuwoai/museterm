# README 演示素材

录制版本：MuseTerm **1.256.0-rc10 / Build 368**，2026-11-06，macOS arm64 Debug，午夜岩蓝皮肤。

| 素材 | 内容 |
| --- | --- |
| `museterm-overview.png` | 新版主界面、项目侧栏与真实示例测试结果 |
| `ai-input-lock.png` | AI 接管标识、输入锁和人工解锁入口 |
| `mcp-ai-takeover.gif` | MCP 接管、执行示例测试、人工解锁并继续输入 |
| `mcp-ai-takeover.mp4` | 同一段窗口录屏的 H.264 视频 |

## 录制过程

素材来自实际运行的应用窗口。独立 QA 副本使用临时工作区、示例 Ruby 代码、专属 bundle ID 和隔离鉴权，不连接日常使用的终端或真实项目。录屏只捕获演示窗口，不包含麦克风或系统音频。

驱动使用应用源码生成的 MCP 工具桥，并通过同一个 stdio MCP 连接执行 `help`、`list_tabs`、`read_screen`、`takeover_tab` 和 `send_text`。运行的 `test_slug.rb` 包含 3 条真实 Minitest 测试，结果为 3 次断言、0 失败、0 错误。随后通过原生鼠标点击“解锁并接管输入”，再使用原生键盘事件运行 `printf`，核实人工输入恢复。完成后关闭专属终端与后台。

这里的 MCP 客户端由录制脚本驱动，没有调用语言模型。GIF 展示的是 Claude Code 等客户端可使用的终端接管能力；它不是 Claude Code 实际推理或调用过程的录像。Claude Code 的接入步骤见[根 README](../../README.md#接入-claude-code)。

## 更新约定

- 更新截图和 GIF 时同步核对应用版本、README 链接与真实操作过程。
- 录制专门准备的示例，不展示凭据、本机用户名、私人目录或真实会话记录。
- 图片和视频只做尺寸、帧率、调色板与编码优化，不拼接或伪造产品状态。
- 生成 GIF 后检查接管、测试输出、解锁和人工输入等关键帧；同时保留 MP4 供更清晰地观看。
