# MuseTerm AppleScript 冒烟测试报告

- 生成时间：2026-11-20T13:00:21+08:00
- 结果：6/10 通过

| 用例 | 说明 | 结果 | 耗时 (ms) | 输出/错误 |
|---|---|---|---|---|
| count_tabs | 统计标签数 | ✅ | 2423 | 1 |
| selected_tab_title | 读取选中标签标题 | ✅ | 442 | [REDACTED_LOCAL_USER] |
| input_allowed | 读取写入开关状态 | ✅ | 272 | true |
| create_tab | 新建标签 | ✅ | 247 | 824EF310-2CD0-4857-A230-58D8C50C3FCF |
| write_text | 写入命令（echo） | ❌ | 206 | 148:211: execution error: “MuseTerm”遇到一个错误：Input was not sent: control was released or the terminal safety check rejecte |
| read_contents | 读取屏幕内容并校验回显 | ❌ | 179 |  |
| send_key | 发送 ctrl-c | ❌ | 167 | 148:184: execution error: “MuseTerm”遇到一个错误：Input was not sent: control was released or the terminal safety check rejecte |
| execute_sync | 同步执行 true 并取退出码（需 shell integration） | ❌ | 30181 | 159:200: execution error: “MuseTerm”遇到一个错误：Command execution timed out. Make sure shell integration is active in the tab |
| command_records | 读取命令记录数量 | ✅ | 209 | 0 |
| close_tab | 关闭最后一个标签 | ✅ | 211 |  |
