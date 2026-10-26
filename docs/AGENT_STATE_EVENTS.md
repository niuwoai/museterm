# 会话事件、Agent 状态与待处理（阶段 0–4）

基础能力基线：`1.250.0-rc2`，Build `315`。普通终端提醒统一与去重见 [rc2 验证报告](../reports/terminal_attention_unification.md)；阶段 0–4 的 `rc1` 证据见 [验证报告](../reports/agent_state_phase234.md)，发行产物见 [GitHub Releases](https://github.com/niuwoai/qterm/releases)。

当前工作区开发版为 `1.251.0-rc34` / Build `348`。普通应用入口已默认启用独立后台，测试宿主仍需显式选择隔离运行；本机安装尚未替换，rc28 完整回归 621/621，另有后补同名同目录项目回归 1/1 通过，未签名 Universal Release 构建及同一 Release 后台的 WillDeep/SSH 验证通过。后台新绑定由服务持有，与 WillDeep 原生上报共用状态；其私有绑定文件保存状态专用上报端点，后续 CLI/MCP 报告直接送到后台，不依赖 UI 查看端或请求处理。绑定与按 UUID 查询仍经现有 UI 工具入口；通用 CLI/MCP 状态、事件读取与有界等待已根据私有元数据自动选定后台，UI 重开不改变服务游标；显式 UI 游标仍走旧路径。后台已接管基于 shell 标记的命令生命周期与精确命令等待；普通提醒也已由后台生成并统一投影，分类阈值有 ACK 更新；项目布局操作已接入在线 UI 工具桥；原方案要求的主窗口/悬浮、中英文窄侧栏、跨项目待处理定位、正常退出及强制结束后同身份恢复分别已有实证；全部组合未穷举。详见[后台实施与验收](WILLDEEP_WORKSPACE_RUNTIME_PLAN.md)。

## 已实现的边界

- 存活会话注册表覆盖主窗口标签和分离的悬浮面板；预热 shell 在被采用前不注册。
- 每个事件中心有独立 `appEpoch`、单调事件序号和最多 1024 条的内存日志。事件只包含元数据，不保存终端正文、命令文本或上报凭据。
- 注册、位置变化、关闭、终端退出、命令开始/结束、输出修订、输入接管变化与 Agent 状态变化使用同一事件中心。
- Agent 身份、活动状态、阻塞原因、最近结果、来源、可信度、时间与规则版本分别记录。输入租约不表示 Agent 任务状态。
- 本机 `claude`、`codex` 启动命令和已识别的前台进程可提供身份线索；屏幕仅识别少量已知审批菜单，保持低可信度。屏幕不认识、前台身份丢失或状态过期时显示未知，绝不靠静默推断空闲/完成。
- 结构化上报支持工作、空闲、等待审批/回答、退出与明确任务结果，优先于屏幕推断。状态有效期为 120 秒，调用方需及时更新；本机观测有效期为 15 秒。
- 主窗口标签提供状态徽标和来源说明；展开与紧凑侧栏均提供待处理入口。通知联动、条件等待已实现；阶段 0–4 基线本身不包含后台保活；当前后台保活与原生 WillDeep 联合实现见下述实施方案。

## 状态专用接入

这里提供显式接入协议，不自动修改 Claude/Codex 用户配置，不声称已安装它们的原生生命周期钩子。上报客户端只需要状态绑定凭据；不会获得输入权限，也不会续租输入控制权。绑定必须通过已有工具客户端配对认证，与“允许写入终端”开关相互独立。

1. 使用 `qterm tabs` 获取终端 UUID。分离会话也可从返回的 `sessions` 元数据获取。
2. 执行 `qterm agent bind --tab UUID --kind codex`（或 `claude`），显式创建新实例。返回状态及本机私有 `bindingFile` 路径，不返回凭据本身。绑定文件为 `0600`，目录为 `0700`。
3. 由接入脚本在生命周期变化时调用：

```sh
qterm agent report --binding PRIVATE_FILE --activity working
qterm agent report --binding PRIVATE_FILE --activity blocked --block-reason approval
qterm agent report --binding PRIVATE_FILE --activity blocked --block-reason question
qterm agent report --binding PRIVATE_FILE --activity idle --result completed
qterm agent status --tab UUID
```

`PRIVATE_FILE` 替换为绑定返回的路径，并按 shell 规则引用路径。不要把文件内容复制到日志、聊天、Git 或环境示例中。每次重新绑定都会使旧凭据失效；旧文件不会自动覆盖，因此迟到的旧钩子不能冒充新任务。报告序号由 CLI 在文件锁内递增，失去响应后下一次报告仍使用更大的序号。普通 UI 直连模式的内存绑定随应用退出撤销，重启需重新绑定；隔离后台模式的新绑定则由原服务和进程代次持有，UI 退出不会撤销。旧绑定文件仍使用旧 UI 路径；带后台端点的新绑定若端点失效会明确报错，不回退创建另一份 UI 状态。绑定文件需手动清理。

对应 MCP 工具为 `bind_agent`、`report_agent_state`、`get_agent_state`。MCP 也只返回绑定文件路径。`idle` 不表示任务成功；应通过明确的 `result` 上报结果。报告被拒绝时不会写入终端，也不会尝试补发批准按键。

## 事件读取

`qterm agent events` 返回当前游标（不默认回放旧事件）。随后可把返回的 `nextCursor` JSON 作为 `--after`，并通过 `--limit` 分页。MCP 对应 `read_session_events`，字段为 `after` 和 `limit`。

- 每个消费者独立读取，不消耗其他消费者的事件。
- `cursor_expired`：日志已裁剪，重新读取完整状态并取得新游标。
- `app_restarted`：该事件中心运行标识不同，丢弃旧游标并重新建立基线；UI 事件中心重启不等于后台任务结束，也不能据此认定后台状态专用绑定失效。
- `future_cursor`：游标序号超前，拒绝读取。
- 快照新增 `eventCursor` 与覆盖悬浮面板的 `sessions` 元数据；旧 `tabs` 数组仍维持可见标签的索引语义。状态工具与输入请求可用精确 UUID 定位分离会话；旧屏幕/历史快照的正文读取仍限于 `tabs` 中的可见标签。
- `snapshotSequence` 仍表示快照写出序号，不代表事件序号。取快照和游标在同一主线程状态上下文内完成。

## 识别局限

屏幕规则只读取实时缓冲区最后最多 12 行/8192 字符，读取与用户滚动位置无关，不复制完整历史。规则可能漏掉新版或本地化审批画面；未知状态不能作为自动输入或审批依据。由 Node、容器、沙箱或其他包装进程承载的 Agent 可能无法通过前台进程名确认，需使用显式上报。SSH 远端身份不从本机 `ssh` 进程推断，需使用本机接入端转交结构化上报；未配置远端钩子。

普通直连模式的状态和事件仅在应用存活期间有效。隔离后台已支持原进程保活、状态及审批连续性；通用事件读取/等待在声明后台来源时使用服务事件中心，显式 UI 游标保留 UI 路径；后台已持有 shell 命令生命周期和命令块等待，项目布局写操作仍需在线 UI。不把历史屏幕回放当作活跃任务。

## 待处理列表

入口展示所有未解决问题和待查看结果。等待审批/回答优先；查看问题只标为已读，不将其解决。结构化上报继续工作、退出、实例替换或终端关闭后解决对应问题。状态过期时问题保留并标为过期，不误认为已经完成。完成/失败摘要查看后清除；普通 `idle` 不生成成功摘要。

待处理生成独立于系统通知总开关。普通终端的响铃、命令失败、长命令完成和进程退出按现有分类开关及阈值进入同一列表；红点来自同一存储中的未读事项，仍受通知及徽标显示开关控制。前台正在查看的普通提醒即时标为已读并解决，不批量确认同标签内的 Agent 问题。设置 › 通知提供 Agent 跟踪与提醒开关；关闭跟踪会撤销状态绑定、只清理 Agent 事项并结束 Agent/待处理等待，保留普通终端事项。重新开启需重新绑定结构化上报。

普通提醒按会话 UUID、事件类型及命令 UUID/进程运行代次去重；即使已读或被列表容量淘汰，同一结束回调也不会在最近 1024 个去重键内重新入列。相同文本的不同命令不合并。连续响铃按同会话、同进程代次合并到当前未解决的响铃事项，更新次数与版本；查看后再次响铃生成新事项。命令结束、进程退出和 Agent 业务结果是不同事件，不凭文本或时间相近误合并。

点击事项或通知定位原标签/悬浮面板；仅对通知携带的准确事项版本标记已读。通知不包含终端正文。待处理事项使用内存存储，保留最多 256 条常规摘要/已解决记录；活动问题不因摘要容量而被淘汰，其数量随存活会话数增长。

```sh
qterm attention
qterm attention read --item ITEM_UUID --version ITEM_VERSION
```

MCP 对应 `list_attention` 和 `acknowledge_attention`。标记已读要求已有客户端配对，不授予终端输入权限。旧版本操作被拒绝，不能误清除新问题。

## 条件等待

先从状态/事件查询获取 `eventCursor` 或 `nextCursor`，再调用 `qterm wait 'SPEC_JSON'` 或 MCP `wait_session`（参数为 `spec`）。以下占位 UUID、序号需要替换为同一应用实例的真实值：

```json
{
  "condition": "commandFinished",
  "after": {"appEpoch": "APP_EPOCH_UUID", "sequence": 123},
  "tabID": "TERMINAL_UUID",
  "commandID": "COMMAND_UUID",
  "timeoutSeconds": 30
}
```

| condition | 额外必需字段 | 匹配语义 |
|---|---|---|
| commandFinished | tabID、commandID | 精确命令结束；另检查返回的 commandState 判断成功/失败/中断 |
| agentState | tabID、instanceID、runID、activity | 精确 Agent 运行实例达到指定状态；idle 不代表业务成功 |
| attention | tabID | 游标之后创建、当前仍未解决的事项 |
| outputChanged | tabID、revision | 输出修订大于给定值；仅表示有变化，不是正文增量流 |
| events | 可选 tabID | 游标之后首条匹配事件；返回该事件游标，下一次不会跳过后续事件 |

默认等待 30 秒，允许 0–60 秒；0 表示只检查一次。结果 outcome 区分 `matched`、`timeout`、`cancelled`、`targetClosed`、`targetReplaced`、`appExited`、`appRestarted`、`cursorExpired`、`futureCursor` 和 `disabled`。终端与 Agent 身份使用准确 UUID，不接受“当前标签”作为等待目标。查询与登记在同一主线程状态上下文执行，避免检查/订阅间隙。

App 内最多 128 个待处理等待/未收取结果，同一客户端最多 16 个活跃等待。所有消费者独立读取，不抢事件。App 端异步登记，不阻塞主线程或输入；MCP 的等待使用独立线程，其他工具调用仍可继续。等待不会自动续租输入控制权；需要保持控制的调用方应自行续租，也可先释放控制再等待。

MCP 按[官方取消约定](https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation)处理 `notifications/cancelled`（`requestId`）；取消后释放 App 等待，不再为该请求发送 MCP 响应。EOF 与 CLI 中断会尝试取消，应用不在线时由有限超时兜底。取消与等待文件乱序到达也能正确处理。过期未收取响应定时清理（5 分钟，保留新近回复）。

客户端等待时只检查很小的私有 `runtime.json`（应用进程标识和运行代次），不重复读取终端正文；检测到进程退出或应用重启时返回对应 outcome。运行元数据缺失/损坏时不会据此推断退出，由有限传输超时兜底。

## 可靠性范围

- 规则版本为 2，包含英文/中文有限审批菜单及对应正反例。仍不从普通日志、问号、`done` 或静默推断任务完成。
- 本机未知包装进程、SSH 远端及不同版本的未覆盖画面需要显式结构化接入；没有自动写入原生 Agent 配置，也没有付费模型验收。
- 内存日志、等待数量、响应保留有边界；高输出测试覆盖 64 个独立等待者、2000 次修订及事件裁剪。
- 界面夹具使用隔离工具目录，不把测试绑定写入已安装应用的工具目录。
