# 独立后台事件与等待端点（开发中）

版本：`1.251.0-rc28` / Build `343`。普通应用默认启用独立后台；测试宿主仍须显式选择隔离运行。本机安装未替换，rc28 完整回归 621/621，另有后补同名同目录项目回归 1/1 通过，未签名 Universal Release 构建及同一 Release 后台的 WillDeep/SSH 验证通过。

通用 `qterm agent events`、`qterm agent status` 和 CLI/MCP 等待已按私有元数据自动选择后台端点，UI 退出或重开不改变已选择的服务游标。后台已持有基于 shell 标记的命令生命周期；原方案阶段实现与约定验收见[实施方案](WILLDEEP_WORKSPACE_RUNTIME_PLAN.md)及完成审计。

rc27 的输入写前校验分别返回 `input_echo_changed`、`input_foreground_changed`，表示预检后安全上下文变化，输入序号尚未消耗，不会自动重发。旧后台仍可能返回 `input_context_changed`，客户端保持普通拒绝处理。订阅连接成功表示可传输，不代表交互 shell 已完成初始化或启动命令已执行。

## CLI/MCP 如何选择事件来源

工具目录的私有 `runtime.json` 保留原 UI 运行信息，另有可选 `backend`：`schemaVersion: 1`、状态专用 `root` 和服务 `cursor`。只有服务声明能力且查看端取得服务游标后，UI 才发布该描述；元数据不包含输入能力凭据。

- 没有指定游标时，事件读取优先使用已声明的后台，返回服务的当前基线。
- 给定服务游标时，等待直接登记在后台；不检查 UI PID 是否存活。
- 显式传入当前 UI 游标仍沿用原 UI 路径。后台命令等待使用服务游标及服务命令 ID，不能用 UI 输入推断的临时 ID 冒充后台命令。
- 已选择的后台端点不可用、权限异常或响应身份错误时直接失败，不回退到 UI 状态。
- MCP 取消/EOF 和 CLI 中断通过所有者标识取消后台等待；不会发送取消请求的额外 MCP 结果，也不续租输入控制权。

| 元数据 | 用途 |
|---|---|
| `qterm tabs.eventCursor` | 原 UI 事件中心游标 |
| `tabs[].runtime.eventCursor` | 该后台终端的服务游标 |
| `tabs[].runtime.outputRevision` | 该后台终端实际 PTY 输出修订，供 `outputChanged` 使用 |
| `tabs[].runtime.commands` | 最近 8 条后台命令元数据，含稳定 ID、进程代次、标记偏移、时间、状态及可选退出码；不含命令正文 |
| `qterm agent events.eventBatch.nextCursor` | 自动选定来源的新基线/下一页游标 |

`snapshotSequence` 不能替代上述游标。私有后台端点还有自己的 `runtime.json`，包含服务 PID/代次和启动游标；等待期间可据此识别服务退出或重建。该启动游标不是持续更新的事件头，重建后需重新查询状态和当前事件基线。

## 身份与权限

- Socket 请求上限保持 128 KiB；会话聚合响应独立限制为 1 MiB，每客户端待发送队列为 2 MiB，PTY 输出块仍为 64 KiB。超大响应返回保留请求身份的 response_too_large，不返回部分会话；旧驻留服务不自动拥有新预算，也不会被强制重启。

- 服务通过协议 3 的 `features` 声明 `event_wait_v1`。旧服务缺少声明时不能假定有这些方法，也不能为升级协议强行重启原进程。
- 只读状态/事件与等待复用服务私有的 `native-tools/requests`、`native-tools/responses` 文件端点。目录为当前用户所有、权限 `0700`，请求和响应 `0600`，原子改名发布；不接受终端输入、配对凭据或控制租约操作。
- 请求 `id` 是 UUID，响应沿用该 ID；等待 `controlID` 是所有者 UUID，仅用于取消和容量隔离，不是输入租约。
- 事件只包含身份、活动状态、时间和修订等元数据，不包含终端文本、命令正文或上报 token。
- 游标字段仍叫 `appEpoch`，在这个端点实际表示**服务运行代次**。不得混用 UI 事件中心的游标。退出或重开 UI 不改变该代次；服务重建则改变代次。

## 方法

| action | 字段 | 行为 |
|---|---|---|
| `get_agent_state` | `tab`：终端 UUID | 查询当前后台 Agent 状态，包括进程已退出后的状态；不返回绑定凭据 |
| `read_session_events` | 可选 `eventCursor`、`eventLimit` | 省略游标取得当前基线；带游标分页读取，消费者互不消耗 |
| `list_attention` | 可选 `tab`：终端 UUID | 服务的同一份有效普通提醒与 Agent 事项，不依赖 UI 存活；读取不等于已读 |
| `wait_session` | `controlID`、`waitSpec` | 异步登记，命中或终止时才写最终响应；不中断服务轮询或 PTY |
| `cancel_wait` | `controlID`、`waitID` | 只取消本所有者的等待；允许取消先于登记到达 |
| `cancel_all_waits` | `controlID` | 取消该所有者的全部等待，随后迟到登记仍会取消 |

取消请求可用 `noResponse: true`，此时不写取消请求自身的确认；原等待仍产生 `cancelled` 结果。请求 ID/所有者必须各自使用 UUID，不能复用固定示例值。

## 等待语义

UI 与后台复用同一 `TerminalWaitCoordinator`，但由各自的串行执行器提供状态快照。检查条件与登记没有跨执行器间隙。

- `agentState`：指定终端、准确 `instanceID` / `runID` 和目标活动状态；新绑定不能冒充原实例。
- `attention`：等待游标之后新创建且仍有效的后台事项；不是把旧的未读事项重复当新事件。
- `events`：等待游标之后的事件，可按终端过滤。
- `outputChanged`：指定终端和 `revision`。这里用服务 `outputRevision`，它只随实际 PTY 字节变化，与含状态/租约变化的通用 `revision` 分开。
- `commandFinished`：服务声明 `command_lifecycle_v1` 后按精确 `commandID` 等待。真实 shell 开始标记创建命令，结束标记的 0/非 0 退出码分别产生 succeeded/failed；新开始标记将旧命令标为 superseded。进程退出且输出排空后仍没有结束标记，或显式关闭时，结束为 completed_unknown_status，不猜测成功或取消。历史保留 200 条，已裁剪或不存在的 ID 返回 targetReplaced。旧服务未声明能力时不能假定支持。

命令 ID 从 PTY 进程代次和开始标记的实际字节偏移确定；实时 UI 使用同一 ID，替换匹配的输入临时记录而不新增同一命令。历史重放不重新触发命令副作用；恢复后可从后台元数据/事件取得原命令身份，但不会凭元数据重建命令正文。Ctrl+C 输入字节本身不能证明后台命令已结束。WillDeep 独立任务绑定不会随普通 shell 命令完成而被关闭。

每个等待允许 0–60 秒，0 为立即检查；协调器最多 128 个等待/待发布完成结果，每个所有者最多 16 个活跃等待。已写出的响应按已有端点最多保留 256 条并定期清理。等待不获取或续租终端控制权。

最终结果使用 `matched`、`timeout`、`cancelled`、`targetClosed`、`targetReplaced`、`appRestarted`、`cursorExpired`、`futureCursor` 等明确 outcome。正常退出服务前，剩余等待得到 `appExited`；这与 UI 退出不同。服务被强杀时不能写最终响应，客户端仍需传输超时和服务代次复核，不能据此当作匹配成功。

原生状态协议 1 的 wire 时间是 Foundation 参考时间数值。CLI/MCP 对外将状态、事件及等待结果中的时间统一转换为 RFC3339；不能直接把原生数值作为 Unix 时间显示。

## 普通终端提醒

服务声明 `terminal_attention_v1` 后，真实 PTY 响铃、明确 shell 命令结束及进程退出由后台写入同一事项存储。UI 只投影与请求已读，不再重复创建；事件版本、游标、列表和红点仍取自同一事项。重连后的历史 BEL 不重新计数，未查看响铃按进程代次合并次数；已读普通事项解决，之后的新响铃生成新身份。

`TerminalReminderPolicy` 与原 UI 复用失败/成功资格规则；分类开关及两个时长阈值随创建请求传入，并通过经过代次校验的 `configureReminders` 更新。设置成功需后台 ACK；离线期间保留最后确认规则，不以系统通知总开关或通知权限决定是否存在事项。旧服务未声明能力时保留 UI 路径，不强制重启。

OSC 的 BEL 结束符、DCS/APC/PM/SOS 载荷不会成为响铃。短失败的错误证据使用该命令最多 16 KiB 的流式可见输出尾部，保留跨帧 VT 状态并排除控制字符串；只保存布尔判断，不把命令或输出正文写入事项/事件。新鲜原生 Agent 状态负责其自身响铃的语义提醒，避免审批与 BEL 双计数；未知/过期且没有语义事项时仍保留普通响铃兜底。

已读请求必须引用准确事项版本。迟到版本/已处理事项会重新读取当前投影，不能清掉后来出现的新版本；同一事项只允许一个 UI 已读请求在途，防止响铃高频更新堆积。普通提醒的系统通知仍由在线 UI 投递，重新接回的历史事项只进入待处理，不补发历史系统通知。

生成 CLI/MCP 的 `list_attention` 在后台元数据声明此能力时直读服务；未声明时沿用原入口。已读仍使用原配对 UI 工具权限，状态专用端点不增加修改事项或输入权限。

## 验证范围

`scripts/verify_runtime_waits.rb` 使用真实私有服务、文件端点和 PTY，覆盖独立消费者、上报/输入继续、所有者取消、提前取消、容量、超时、代次/游标、身份替换和正常服务退出。`verify_willdeep_native.rb` 的后台模式在服务声明能力时，还会实际等待原 WillDeep 审批后的完成；缺少能力时保留旧模式。

最新结果及未完成项见[验证索引](verification/willdeep-workspace-runtime/README.md)。实际生成 CLI/MCP 的自动路由、取消和 EOF 已有真实服务测试；命令和普通提醒已有实际 PTY/查看器验证，这些结果仍不替代全部 GUI、异常退出和远端 SSH 联合验收。
