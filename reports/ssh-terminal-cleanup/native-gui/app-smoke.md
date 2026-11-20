# 原生应用隔离冒烟验证

- 版本：1.261.0-rc3
- 结果：FAIL
- 范围：启动实际 QA App，使用项目已有 AppleScript 脚本创建标签、执行命令、读取屏幕与命令记录，并关闭测试标签。
- 此项验证原生应用与终端输入；SSH 异常退出的屏幕恢复由原生回归测试单独覆盖。
- 复用建议：可通过 /run-skill-generator 固化本次隔离启动参数及项目已有的 AppleScript 驱动。

```json
{
  "generatedAt": "2026-11-20T04:59:43Z",
  "scope": "Actual isolated macOS application, driven through the existing AppleScript smoke test",
  "success": false,
  "applicationVersion": "1.261.0-rc3",
  "initialTabCount": 1,
  "appleScriptExitStatus": 1,
  "smoke": {
    "app": "$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app",
    "generated_at": "2026-11-20T13:00:21+08:00",
    "total": 10,
    "passed": 6,
    "failed": 4,
    "cases": [
      {
        "name": "count_tabs",
        "description": "统计标签数",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\ncount tabs\nend tell",
        "passed": true,
        "stdout": "1",
        "stderr": "",
        "duration_ms": 2423
      },
      {
        "name": "selected_tab_title",
        "description": "读取选中标签标题",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nget title of selected tab\nend tell",
        "passed": true,
        "stdout": "[REDACTED_LOCAL_USER]",
        "stderr": "",
        "duration_ms": 442
      },
      {
        "name": "input_allowed",
        "description": "读取写入开关状态",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nget scripted input allowed\nend tell",
        "passed": true,
        "stdout": "true",
        "stderr": "",
        "duration_ms": 272
      },
      {
        "name": "create_tab",
        "description": "新建标签",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nset t to create tab\nget id of t\nend tell",
        "passed": true,
        "stdout": "824EF310-2CD0-4857-A230-58D8C50C3FCF",
        "stderr": "",
        "duration_ms": 247
      },
      {
        "name": "write_text",
        "description": "写入命令（echo）",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nwrite text \"echo museterm-applescript-smoke\" to selected tab\nend tell",
        "passed": false,
        "stdout": "",
        "stderr": "148:211: execution error: “MuseTerm”遇到一个错误：Input was not sent: control was released or the terminal safety check rejected it. (-31004)",
        "duration_ms": 206
      },
      {
        "name": "read_contents",
        "description": "读取屏幕内容并校验回显",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nget contents of selected tab\nend tell",
        "passed": false,
        "stdout": "[REDACTED_LOCAL_USER]@[REDACTED_LOCAL_HOST] [REDACTED_LOCAL_DIRECTORY] %",
        "stderr": "",
        "duration_ms": 179
      },
      {
        "name": "send_key",
        "description": "发送 ctrl-c",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nsend key \"ctrl-c\" to selected tab\nend tell",
        "passed": false,
        "stdout": "",
        "stderr": "148:184: execution error: “MuseTerm”遇到一个错误：Input was not sent: control was released or the terminal safety check rejected it. (-31004)",
        "duration_ms": 167
      },
      {
        "name": "execute_sync",
        "description": "同步执行 true 并取退出码（需 shell integration）",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nset r to execute \"true\" in selected tab timeout 30\nget exit code of r\nend tell",
        "passed": false,
        "stdout": "",
        "stderr": "159:200: execution error: “MuseTerm”遇到一个错误：Command execution timed out. Make sure shell integration is active in the tab, or increase the timeout parameter. (-31008)",
        "duration_ms": 30181
      },
      {
        "name": "command_records",
        "description": "读取命令记录数量",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\ncount command records of selected tab\nend tell",
        "passed": true,
        "stdout": "0",
        "stderr": "",
        "duration_ms": 209
      },
      {
        "name": "close_tab",
        "description": "关闭最后一个标签",
        "script": "tell application \"$WORKSPACE/.derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app\"\nclose tab (count tabs) skipping confirmation true\nend tell",
        "passed": true,
        "stdout": "",
        "stderr": "",
        "duration_ms": 211
      }
    ]
  },
  "screenshot": "$WORKSPACE/reports/ssh-terminal-cleanup/native-gui/native-terminal.png",
  "privateBackendCleanup": true
}
```
