# 项目 CLI/MCP 与实际原生界面联合验收

日期：2026-10-24。当前版本 1.251.0-rc19 / Build 334。

结果：单窗口中文原生 QA 的 14 项项目操作通过。当前生成 CLI 的业务代码和真实 MCP stdio 均连接实际 GUI 工具桥与真实 PTY，没有用内存工作区替代原生 App。

## 授权隔离

正式配对服务使用全局钥匙串。为避免使用、改写正式凭据，本轮增加仅 DEBUG 的 TerminalToolAccessTestFixture：必须同时为 goaltests 专用 bundle、显式环境开关、固定层级的私有 QA 根和 0700 目录；0600 普通凭据文件有大小、所有者、客户端前缀、token 格式及 O_NOFOLLOW 校验。启用后只使用当前 QA 进程内的测试存储，并复用现有 TerminalToolAccess.authorizes 检查；夹具错误保持写入关闭，且不回退系统钥匙串。

本轮使用独立 bundle ID 和偏好域，生成 CLI 仅适配 ROOT、测试 clientID 和凭据读取函数，项目/MCP 业务代码保持当前导出内容。它不等同于安装后的普通 qterm 通过正式钥匙串运行；适配前后 SHA 与方式均保存在 JSON。实际测试令牌不写入报告或仓库。

## 实际操作

1. list 取得准确工作区和原始终端 UUID/PID/代次。错误凭据的创建请求明确拒绝，没有新增项目。
2. CLI createProject、createTab、split 在后台创建两项目及四个新 PTY；五个终端均就绪，后台目录匹配请求，原 UI 选择和原进程身份保持。CUA 实际观察侧栏项目/分屏增加，而主画面仍是原终端。
3. CLI renameProject、moveTerminal、moveTab、reorderProjects、reorderTabs，及真实 MCP stdio resizeSplit 完成；所有移动前后 UUID/PID/代次保持，分屏比例实际为 0.65，显式 focus 前没有抢焦点。
4. CLI focus 后，CUA 实际观察目标项目及其两分屏布局，原生输入 printf 组装完整标记；状态检查证明标记仅在目标终端，其他四个终端没有该输出。
5. CLI closeTerminal、closeTab 和 MCP stdio closeProject 的回执均只声明 processClosure=requested。之后分别等待后台记录移除及相应 PID 消失，才确认进程已结束；关闭空源项目后，GUI 和后台都只剩原始终端，焦点回到它，身份保持。
6. CUA 正常退出 QA，确认 UI 不在后，仅关闭本轮最后一个测试 PTY 及空后台。测试凭据文件已删除；进程内凭据随 QA 退出消失，正式配对未操作。

14 个操作名称均在报告中去重核对，没有用一个操作泛化其他操作。实际 MCP 通过 initialize 和 tools/call 两个 JSON-RPC 请求执行写操作，包含版本校验；不是直接调用 Ruby call_tool 函数冒充 stdio 验证。

## 测试与证据

- [实际 CLI/MCP GUI 报告](project-cli-gui.json)：操作回执、后台/焦点/布局、原 PID/代次、移动身份、MCP 比例、单终端输入标记、关闭请求与实际 PID 结束分开核验，以及清理结果；不含 token/authToken/agentGrant。
- [定向与完整测试](project-cli-gui-unit.json)：最终定向 4/4、完整 609/609，0 失败、0 跳过。包含权限过宽、链接文件/目录、普通 clientID 和超大夹具拒绝。两次初始定向失败也保留：父目录创建方式和 macOS /private/tmp→/tmp 规范化导致合法夹具误拒绝；修正固定目录结构和逐层 lstat 校验后通过，没有放松所有者/权限/链接限制。
- 未定义 DEBUG 时独立编译该夹具文件成功，产物中不含环境开关或夹具文件名，确认条件编译排除；这不是完整 Release App 构建/签名/发版证明。
- 私有准备与操作脚本分别为 `/private/tmp/prepare_qterm_project_cli_qa.rb`、`/private/tmp/qterm_project_cli_gui_probe.rb`、`/private/tmp/qterm_project_cli_gui_finalize.rb`；QA 元数据 `/private/tmp/qterm-native-qa-e143e78d6535/qa.json`。CUA 截图显示在工具输出中，本轮未持久化 PNG。

启动 QA 的一次界面工具调用耗时异常；返回后先重新读取实际状态和已结束的全量测试句柄，再继续，没有据观察延迟重启测试或后台。本轮不作为启动性能测量。

## 范围

该用例为普通终端的项目工具联合流程，没有运行真实 WillDeep 任务；原生 WillDeep/审批保活已有独立报告。多窗口/全布局/英文/窄窗口/悬浮、长标题快捷键挤压、不兼容后台/损坏端点、远端 SSH 和系统通知仍待收尾，不能据此宣布整体完成。正常后台入口继续关闭，未提交、未发版、未替换本机应用或正常 WillDeep Runtime。
