# 项目、布局标签和分屏工具（开发中）

版本：`1.252.0-rc1` / Build `348`。普通应用已默认启用独立后台；本机安装未替换，rc28 完整回归 621/621，另有后补同名同目录项目回归 1/1 通过，未签名 Universal Release 构建及同一 Release 后台的 WillDeep/SSH 验证通过。

CLI 使用 `qterm project OPERATION [REQUEST_JSON]`；MCP 使用 `project_layout`，参数是同一个请求对象。`list` 直接查询在线 UI 的工作区，其他操作要求现有工具配对和“允许已授权客户端写入”开关；不授予 Agent 上报凭据额外权限，也不为操作布局获取或续租输入控制。

先读取响应中的 `projectResult`，从返回值取得准确 UUID。项目 ID、布局标签 ID、分屏 ID 和终端 ID 不同；原来的 `list_tabs` 仍按终端叶子列举，不能把它的终端 ID 当作布局标签 ID。

```sh
qterm project list
qterm project createProject '{"name":"review","directory":"/absolute/project/path"}'
qterm project split '{"terminalID":"<returned-terminal-uuid>","axis":"vertical"}'
qterm project moveTab '{"layoutTabID":"<returned-layout-tab-uuid>","projectID":"<returned-project-uuid>"}'
```

示例路径必须替换成已存在的绝对目录；占位 UUID 必须替换成响应返回值。

## 操作与结果

| operation | 主要字段 | 行为 |
|---|---|---|
| `list` | 可选 `workspaceID` | 当前完整布局、运行代次、布局修订和按项目汇总的待处理/未读/Agent 状态 |
| `createProject` | `name`，可选 `directory` | 新项目及其首个本地终端 |
| `renameProject` | `projectID`、`name` | 保持项目身份重命名 |
| `createTab` | `projectID`，可选 `directory` | 在指定项目添加布局标签和根终端 |
| `split` | `terminalID`、`axis` | 复制该终端的入口配置，创建新终端叶子；已有终端保持原进程 |
| `moveTerminal` | `terminalID`、`projectID` | 将单个叶子移入目标项目的独立标签，原分屏树自动收拢 |
| `moveTab` | `layoutTabID`、`projectID` | 移动整棵分屏树，保留标签、分屏和终端全部身份 |
| `reorderProjects` | `order` | 必须包含每个现有项目 ID 一次，保持各自选中状态 |
| `reorderTabs` | `projectID`、`order` | 必须包含该项目每个现有布局标签 ID 一次 |
| `resizeSplit` | `splitID`、`ratio` | 比例必须在 0.1–0.9 之间且有限 |
| `focus` | `terminalID` / `layoutTabID` / `projectID` | 显式定位；查看可标为已读，但不回答 Agent 问题 |
| `closeTerminal` | `terminalID` | 移除叶子并请求关闭对应进程 |
| `closeTab` | `layoutTabID` | 关闭该标签所有叶子 |
| `closeProject` | `projectID` | 关闭该项目所有叶子并移除项目 |

写操作默认 `focus: false`：保持当前项目和可保留的当前叶子，不把源终端或其他终端的提醒标为已读。移动/关闭当前叶子时，原项目若仍存在则保留该项目，并选择其剩余叶子；否则使用剩余布局的有效选择。`focus: true` 或显式 `focus` 才允许选中操作目标。后台分屏/移动不重建原终端，也不修改 WillDeep task/run 身份。

## 就绪、关闭和并发

- 创建返回的是布局身份，`terminalState` 为 `running` / `not_ready`；应通过终端状态、实际输出或 Agent 状态确认所需就绪条件，不能根据收到 UUID 就发送业务命令。
- 独立后台启用时，新终端无需等待窗口挂载即可创建 PTY；未挂载使用默认 80×24，真正挂载后再同步实际尺寸。此行为与原有本地进程路径的窗口启动条件分开。
- 运行中终端的关闭必须显式传 `terminateRunning: true`，否则返回 `terminate_running_required`，不会弹出模态确认框阻塞工具。关闭响应 `processClosure: requested` 只证明布局删除及关闭请求已发出；后台事件或查询确认结束后才能声称原进程已关闭。
- 每次响应包含 `workspaceID`、`appEpoch` 和 `revision`。请求可带 `workspaceID` 固定工作区，并同时带 `expectedEpoch` / `expectedRevision` 检查布局是否变化；任一不匹配都拒绝执行。UI 重启后不能复用旧修订。
- CLI 自动绑定当前 `uiEpoch` 和最长 60 秒的 `deadlineMonotonic`；直接文件桥调用也必须携带这两个字段，缺失即拒绝。Swift/Ruby 共用 macOS `CLOCK_MONOTONIC`，不混用基准不同的进程 uptime。超时会清理未接收的文件，过期或跨 UI 运行代次请求拒绝执行。已经接收的操作不能凭客户端超时认定撤销，应重新查询布局，不自动重发写操作。
- 所有目标使用完整 UUID；目录不存在、名称无效、目标缺失、重复/缺漏的重排序列、非法比例在执行前拒绝。工具创建限制为最多 64 项目、64 终端；不因超限关闭其他进程。
- 布局仍归在线 UI 工作区持有，UI 不在线时不伪造可修改布局。独立后台继续保留 PTY、Agent 状态与待处理；这与后台可读事件/等待端点的可用性不同。

实现与测试状态见[实施记录](WILLDEEP_WORKSPACE_RUNTIME_PLAN.md)和[验证索引](verification/willdeep-workspace-runtime/README.md)。
