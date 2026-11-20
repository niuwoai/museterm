# @niuwoai/museterm

MuseTerm 的命令行。安装后得到 `museterm` 命令：读取本机正在运行的 MuseTerm 里的标签、屏幕和命令记录，也能以 MCP 服务器的形式，向已经配对的 AI 工具提供终端操作。

```bash
npm install -g @niuwoai/museterm@rc
museterm tabs
```

当前版本是 `1.256.0-rc4`，与桌面版一致。发布标签是 `rc`，不要省掉 `@rc`，否则 npm 会去找尚不存在的 `latest`。

## 它是什么

这个包本身不含终端程序。安装时它会从公开地址 `https://img.niuwoai.com/mac-apps/cli/<版本>/` 下载与本版本对应的命令行，核对 SHA256 后放到包内的 `bin` 目录。命令行是一段 Ruby 脚本，通过本机文件与正在运行的 MuseTerm 交换状态，所以使用前需要先打开 MuseTerm。

下载只接受 `img.niuwoai.com` 的 HTTPS 地址，校验不符或压缩包内容异常都会中止安装。源码仓库不公开，GitHub Release 附件匿名访问不到，所以命令行压缩包放在上面这个公开地址。

## 环境要求

- macOS。命令行只随 macOS 版 MuseTerm 发布，Intel 与 Apple 芯片使用同一份 universal 包。
- Node.js 18 或更高版本。
- 本机已安装并打开 MuseTerm，版本与本包一致。

## 常用命令

```bash
museterm tabs                                          # 列出标签
museterm screen --tab <UUID>                          # 读取一个标签的可见屏幕
museterm history --tab <UUID>                         # 读取滚动历史
museterm commands --tab <UUID>                        # 读取结构化命令块
museterm input --tab <UUID> 'echo hello'              # 向标签发送文本（需先接管）
museterm mcp                                           # 以 MCP 服务器运行
```

完整命令列表：

```text
museterm tabs
museterm screen [--tab selected|INDEX|ID] [--chars N] [--json]
museterm history [--tab selected|INDEX|ID] [--chars N] [--json]
museterm commands [--tab selected|INDEX|ID] [--chars N] [--query QUERY]
museterm input [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] TEXT
museterm key [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] enter|ctrl-c|tab|escape|up|down|left|right
museterm tab [--timeout SECONDS] [--json] [DIRECTORY]
museterm ssh [--timeout SECONDS] [--json] PROFILE_NAME
museterm tunnels
museterm tunnel presets
museterm tunnel start [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] --target-host HOST --target-port PORT --local-port PORT [--name NAME]
museterm tunnel stop [--tab selected|INDEX|ID] [--timeout SECONDS] [--json]
museterm shortcuts [--timeout SECONDS] [--json]
museterm shortcut [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] SHORTCUT_TITLE
museterm shortcut save --title TITLE [--replace OLD_TITLE] [--no-return] [--touch-id] [--no-automation] --step TEXT [--step TEXT ...]
museterm mcp
museterm attention [read --item UUID --version N] [--tab UUID]
museterm wait SPEC_JSON
museterm project OPERATION [REQUEST_JSON]
museterm preview [--tab UUID] FILE_OR_--stdin_OR_--close
museterm agent bind --tab UUID --kind claude|codex
museterm agent report --binding PRIVATE_FILE --activity working|idle|blocked|unknown|exited [--block-reason approval|question|other] [--result completed|failed|interrupted|unknown]
museterm agent status --tab UUID
museterm agent events [--after CURSOR_JSON] [--limit N]
```

## 接入 MCP

在 MCP 客户端的配置里加入：

```json
{
  "mcpServers": {
    "museterm": {
      "command": "museterm",
      "args": ["mcp"]
    }
  }
}
```

写入类操作（发送输入、按键、接管标签）需要先在 MuseTerm 的设置里开启工具桥写入，并完成本机配对授权。每个 MCP 进程有各自的接管身份：操作一个标签前先用它的 UUID 调用 `takeover_tab`，再发送输入；租约 120 秒无输入或续租即释放，用完调用 `release_tab`。

## 桌面应用

命令行依赖桌面版 MuseTerm。下载地址：

- 当前版本：<https://img.niuwoai.com/mac-apps/MuseTerm-1.256.0-rc4.dmg>
- 最新版：<https://img.niuwoai.com/mac-apps/latest/MuseTerm.dmg>
- Homebrew：`brew install --cask niuwoai/tap/museterm`

## 许可

MuseTerm 为专有软件，本包随应用一同分发，未授予再分发许可。
