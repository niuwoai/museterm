# WillDeep 原生状态、项目布局与终端后台验证

## 最新：2026-10-25 / 1.251.0-rc28，Build 343

- [跨项目待处理导航及弹层修复](attention-navigation-gui.md)：实际点击另一项目的原问题后，定位正确叶子并自动关闭弹层；不加 Escape 或分屏点击，直接粘贴执行仅到原目标。问题仅已读、仍为唯一待处理，三个原 PTY 身份保持；QA 退出/更新/重开恢复与最终清理均核实。
- [完整回归](attention-navigation-full-unit.json) 621/621，通过且无跳过；随后补充的[同名同目录项目独立身份/提醒用例](same-directory-project-unit.json) 1/1 通过，两份结果分别保留，不混称同一包 622/622。
- [当前未签名 Universal Release 构建](release-universal-build.json)通过；完整 Release App 未安装或启动。当前跨进程与原方案核对结果见 completion-audit.md。
- 当前同一 Release helper 的[真实 WillDeep/CLI 双等待](release-native-continuity-rc28.json)与[SSH 10 项](release-authenticated-ssh-rc28.json)通过；[Rust 原生模块](willdeep-native-unit.json)离线 16/16。原方案阶段 0–5 的实现与约定验收完成，范围、失败处理及未覆盖项详见[完成审计](completion-audit.md)。
- WillDeep 隔离源码另有[可审查补丁](willdeep-native-source.patch)及[基线/摘要/干净索引应用校验](willdeep-native-source.json)，含四个新增源文件；没有提交、发布或改动正常 WillDeep 检出。

## 前一阶段：2026-10-24 / 1.251.0-rc27，Build 342

- [重启输入审计](restart-audit.md)捕获到具体的 echo 初始化变化：原用例仅等订阅连接就输入，正确触发写前安全拒绝。保留原 `/bin/sh -i`，改为等待实际提示符；重启输入、安全拒绝后显式新输入各重复 60 次，共 [120/120](restart-shell-ready-iterations.json) 通过。两轮初始失败仍保留。
- 当前[完整回归](context-full-unit.json) 621/621，0 失败、0 跳过；[实际后台协议](context-service.json) 21 项通过，包括 echo 与前台进程分别拒绝、不消耗输入序号、去重和慢消费者。
- 当前[未签名 Universal Release 构建](release-universal-build-rc27.json)、[同一 Release 后台的真实 WillDeep 连续性与 CLI 双等待](release-native-continuity-rc27.json)、[真实回环 SSH 10 项](release-authenticated-ssh-rc27.json)通过，三个报告的 helper SHA 一致。
- 输入安全校验及拒绝保持，两个具体诊断码不含输入内容；不会自动重发被拒绝的输入。当前没有发布或安装，也没有启动 Release App；界面历史证据与新增候选范围分别保留，整体收口仍以阶段验收清单为准。

## 前一阶段：2026-10-24 / 1.251.0-rc26，Build 341

- 普通应用源码默认启用独立后台；测试宿主仍须显式选择隔离后台。当前[完整单测](runtime-default-full-unit.json) 621/621，通过且无跳过。
- [Universal Release 构建](release-universal-build-rc26.json)通过，App 与内嵌 helper 均包含 arm64/x86_64，排除 QA 专用入口及 XCTest 链接。这是未签名构建，没有安装或启动 Release App。
- 同一最终 Release helper 的[真实 WillDeep 连续性及 CLI 双等待](release-native-continuity.md)通过：所有查看端离线 31 秒后保留原审批，批准后同一任务完成；[真实回环 SSH](release-authenticated-ssh.md) 10 项通过，临时密钥已清理。
- rc25 [真实 SSH Profile/SwiftTerm 控制器](authenticated-profile.md)定向 3/3、完整 619/619，覆盖手动/自动重连、重试上限、错误主机密钥禁止自动重试。使用离屏 AppKit 窗口，不冒充完整 App 菜单或外部机器验收。
- 当前审计见[阶段验收核对](completion-audit.md)。历史输入 ACK 间歇失败根因仍未确认，更多界面组合和系统通知实际投递未覆盖；没有据此标记整体完成。本机应用及正常 Runtime 未动，未提交、未发版。
- 后续[重启输入重复审计](restart-audit.md)再次失败，首次明确捕获 `input_context_changed` 且输入序号为 1：写前安全上下文变化导致拒绝，尚未执行输入，不能归为已写入后 ACK 丢失。继续核对 shell 初始化及启动回调；不以完整单次绿色结果覆盖重复失败。WillDeep 当前隔离检出原生模块重新验证 16/16 通过。

## 前一阶段：2026-10-24 / 1.251.0-rc24，Build 339

- [损坏端点与真实 SSH 认证/断连](compatibility-and-authenticated-ssh.md)：新增 Swift 客户端 5 项故障回归通过，实际原后台/PTY 仍能输入；拒绝协议、响应/身份/大小或代次异常，不触发替代启动。
- 定向 5/5、完整 616/616，0 失败、0 跳过。真实回环 OpenSSH/实际 QTerm helper/PTYS 的 10 项认证、查看端重连、网络断开、显式重连及错误密钥拒绝检查通过；故意让 helper 启动失败的夹具清理也通过。
- SSH 严格目录检查的初始夹具失败保留。最终不降低 StrictModes 或主机校验，临时授权目录由 Git 忽略并完全删除，不启用系统远程登录或修改用户 SSH 配置。
- 这是受控故障端点与回环真实 SSH，不冒充更多历史服务版本、外部机器或 GUI/Profile 联合验收。正式入口仍关闭，整体目标未完成；本机应用及正常 Runtime 未动，未提交、未发版。

## 前一阶段：2026-10-24 / 1.251.0-rc23，Build 338

- [悬浮粘贴、收回与真实 WillDeep 审批](floating-paste-native.md)：主窗口/悬浮/收回三次实际粘贴仅到原终端，原三个 PTY/PID/代次保持；完整粘贴单请求、安全检查原正文，拒绝不发送开始标记；悬浮控件可见并实际收回成功。
- 实际 WillDeep/私有 Runtime/本机 mock 模型原生提交、唯一审批跨悬浮/收回保持，批准后唯一完成；点击只清除该任务，另一终端的问题保留。实际退出后原 shell 恢复；测试驱动通过、模型请求 2 次、fixtureErrors 为空。
- 干净 zsh 基线 1/1，定向 3/3，首轮完整 611/611；补齐输入法组合态断言后最终完整回归 611/611、0 失败、0 跳过，见 atomic-paste-final-full-unit.json。普通粘贴 GUI 候选与最终输入法补充构建分开记录，不将前一构建结果自动套给新改动。
- 本轮 QA、三个自有 PTY、空后台、私有 Runtime/测试凭据及独立偏好已回收。正式后台入口仍关闭，未提交、未发版、未替换本机应用。多窗口/全布局/其他语言悬浮、远端 SSH、系统通知、更多异常/兼容与正式构建仍待完成，原间歇性重启输入失败继续保留诊断。

## 前一阶段：2026-10-24 / 1.251.0-rc22，Build 337

- rc21 英文实际原生 QA 在 220 点展开侧栏显示长终端标题、完整单行 `⌘2`、第二行 shell/Agent 状态，以及项目待处理 1；折叠态也已观察。使用合成 Agent 协议展示夹具，不冒充真实 WillDeep 任务。自有三个 PTY、空后台、私有凭据及 QA 偏好已回收。
- 中文 QA 首次界面连接工具超时且未启动，后续成功启动。初次后台连接失败、工具创建请求超时，核对后台仅原 PTY 后显式重新连接，保持原 PID/代次；随后创建夹具成功。中文 220 点展开/折叠布局、完整单行快捷键，以及待处理数字 1/项目 1/弹出列表唯一事项实际核对通过。前一版标题近乎不可读的中间结果保留；中英文展示均采用 rc21 两行布局，见 sidebar-layout-en.json / sidebar-layout-zh.json。
- rc21 完整并行回归 602/609、6 失败、1 跳过；同构建串行回归 608/609、1 失败、0 跳过。剩余为已退出 PTY 重启后输入未执行；原样重复 12 次仍有失败，不能以单次定向通过或 rc19 的 609/609 代替当前结果。
- rc22 增加 ACK 阶段诊断；初始 12 次诊断重复中 11 次通过、1 次在输入 ACK 阶段超时，输入序号仍为 1，不能断言后台已接收后被 shell 清空。保留安全错误码后重启用例 12/12，两项回归各重复 40 次共 80/80，最终完整串行回归 610/610、0 失败、0 跳过。后续输出不再清除输入拒绝/过大提示，成功写入后才清除；间歇性重启失败根因仍未确认，不以最新通过覆盖此前失败。见 input-issue-diagnostics.md / input-issue-full-unit.json。
- 中文隔离 QA 的项目分屏实际分离到悬浮面板，普通键入输出 `__QTERM_FLOATING_TYPED_OK`；粘贴失败，出现 `[200~` 残留和 zsh bad pattern，控制条也未能通过当前界面操作显现，尚未验证收回。不得将悬浮路径记为通过。中文自有三个 PTY、空后台、私有凭据及独立偏好均已精确核对并回收；后续继续定位粘贴/控制条及初次连接边界。
- 原始结果：`/private/tmp/qterm-sidebar-two-row-full-01.xcresult`、`/private/tmp/qterm-sidebar-two-row-serial-01.xcresult`、`/private/tmp/qterm-restart-diagnose-repeat-01.xcresult`、`/private/tmp/qterm-restart-ack-diagnose-01.xcresult`。英文 QA 脱敏元数据：`/private/tmp/qterm-native-qa-281c1420d59f/sidebar-layout.json`。
- 目标未完成，正式后台入口仍关闭；本机 QTerm 仍为 1.250.0-rc1 / Build 314，未提交、未发版、未替换。

## 最新结果：2026-10-24 / 1.251.0-rc19，Build 334

- [项目 CLI/MCP 实际 GUI 联合验收](project-cli-gui.md)：14 项操作通过，包含错误凭据拒绝、后台创建/分屏不抢焦点、移动保持原进程、重排、真实 MCP stdio 比例调整与关闭、显式定位后单终端原生输入；关闭回执 requested 与后台记录/PID 实际消失分别验证。五个测试 PTY、QA 和空后台已退出，私有凭据已删除。
- 仅 DEBUG 的专用 bundle/私有目录内存凭据夹具避免正式钥匙串；最终定向 4/4、完整 609/609，0 失败、0 跳过。两个初始夹具失败及修正均保留；非 DEBUG 独立编译检查夹具入口排除，没有据此声称完整 Release 构建。
- 多窗口/全布局/英文/窄窗口/悬浮、长标题快捷键、更多后台兼容/损坏端点、远端 SSH 及系统通知仍待收尾。正常入口继续关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc18，Build 333

- [实际旧后台兼容及原生审批恢复](old-backend-compatibility.md)：当前 UI 接入先运行的真实 rc5/protocol3 后台及原 PTY，输入/正常退出恢复通过，缺失能力明确 unsupported_feature、不误发布后台事件端点。当前 WillDeep 在该原 PTY 的审批跨 UI SIGKILL/离线至少 51.700 秒恢复，原进程/task/gate/唯一审批保持，批准完成及点击已读清零；仅回收本轮实例。内嵌候选 helper 与实际旧进程 SHA 分开留证。
- [最大会话响应容量](runtime-capacity.md)：修复前合法引号长路径第 56 会话列表 EOF；修复后 64 会话引号/控制字符目录分别完整读取约 309/535 KB，身份/全部命令/最大 Agent 上下文保持，第 65 会话拒绝且原身份不变。Swift 实际连接器也验证了超过旧预算的完整列表。
- 定向 3/3、完整 605/605；同一 Universal helper 的 21 项后台、11 项等待、8 项提醒及真实 WillDeep/当前生成 CLI 双等待通过，查看端离线 31 秒仍保留唯一审批。容量用例只清理各自测试 PTY/空后台。
- 请求维持 128 KiB，响应 1 MiB、队列 2 MiB，超大响应明确返回错误。旧驻留服务不会被强制更新；rc5 同协议主路径已验证，不兼容协议/损坏端点/其他版本与旧容量边界、完整项目工具 GUI 等仍待验收。正常入口保持关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc17，Build 332

- [项目/分屏实际界面及修复](project-layout-gui.md)：中文单窗口两项目，混合方向三分屏及第四个项目目录终端，分别实际输入；移动保持原身份，拖动比例与完整布局恢复，取消/确认关闭及再次恢复通过。发现并修复纯布局工具快照陈旧和首次重命名打开错误表单，保留复现证据。
- rc16 定向 1/1、完整 602/602；最终 rc17 完整 602/602，0 失败、0 跳过。本轮测试 QA、剩余三个 PTY 及空后台已回收，正式应用未动。
- 仍需完整 CLI/MCP GUI 写操作、多窗口/全布局/悬浮/英文/窄窗口、长标题快捷键显示、远端 SSH、旧服务、系统通知及合法最大元数据帧验收。正常入口仍关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc15，Build 330

- [WillDeep 审批跨 UI 强制结束恢复](native-forced-ui.md)：真实 QA App SIGKILL、离线 42.534 秒、重开后保持原后台/PTY/WillDeep/task/gate/唯一审批；原生批准后唯一完成，点击已读后 UI/后台清零。只回收本轮 QA/PTY/私有后台，正常应用不变。
- [已读回调完整性](ack-callback-unit.md)：最终定向 3/3、完整回归 601/601，0 失败、0 跳过。真实 PTY 验证在途重复调用明确完成、旧版本不清除新提醒、最新版本重试、界面重复点击不误报断线，以及查看器释放后回调仍返回。
- 仍需项目工具完整 GUI、多窗口/全布局、远端 SSH、旧服务、系统通知及合法最大元数据帧验收；正常后台入口关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc14，Build 329

- [解析检查点完整回归](render-checkpoint-unit.md)：599/599 通过，0 失败、0 跳过。含实际 PTY 消费边界、持续输出下两次保存前进、没有正常退出保存时重建并保持原 PID/唯一事项；未保存窗口不承诺零丢失。
- [实际 App 强制结束恢复](render-checkpoint-crash-ui.md)：SIGKILL 仅作用于验证过的隔离 QA App；重开后原 PID/代次及焦点保持，旧命令没有重新处理，离线命令正常出现。CUA 实际核对待处理 1、同事项合并 2 次，点击后数字 0/列表空/未读清除；自有 UI/两个终端/后台已清理。该场景为 zsh 普通提醒，尚非 WillDeep 审批强制结束联合验收。
- 独立 Universal helper 的[8 项提醒](render-checkpoint-reminder.md)、[11 项等待](render-checkpoint-waits.md)、[21 项后台回归](render-checkpoint-regression.md)及[实际 WillDeep + 当前 CLI](native-render-checkpoint.md)再次通过：所有查看客户端离线 31 秒仍保留唯一审批，批准后双等待匹配同 task completed。GUI 签名 helper 与该 Universal helper 的 SHA 分开留证。
- 仍缺 WillDeep 审批强制结束、新建项目工具完整 GUI、多窗口/全布局、远端 SSH、旧服务及系统通知验收；正常后台入口关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc13，Build 328

- [项目工具完整回归](project-tools-unit.md)：597/597 通过，0 失败、0 跳过。真实配对桥及生成 CLI/MCP，写开关/错误凭据拒绝，14 项操作契约，移动/重排保持身份、默认焦点/未读、空项目目录、整标签/项目关闭，以及过期/旧 UI/超时文件清理。此前工具目录断言与夹具问题及所有中间结果保留在 JSON。
- 实际 PTY 项目移动保持同 PID/代次/Agent 和同一未读审批；关闭需要显式意图，响应仅确认请求发出，测试另行检查后台移除。无 NSWindow 的真实查看器保持 80×24，未冒充完整 App 后台创建入口验收。
- 相同 Universal helper 通过[8 项提醒](project-tools-reminder.md)、[11 项等待](project-tools-waits.md)、[21 项后台回归](project-tools-regression.md)；[实际 WillDeep + 最终生成 CLI](native-project-tools.md)在全部查看客户端离线 31 秒后保持唯一审批，批准后双等待匹配同 task completed。helper 与当前 CLI 源 SHA 分别绑定。
- 项目协议见[PROJECT_LAYOUT_TOOLS](../../PROJECT_LAYOUT_TOOLS.md)。仍需完整 App 后台新建/布局工具联合验收、异常退出、全部布局/跨窗口/远端 SSH 及系统通知验收；正常后台入口关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc12，Build 327

- [后台普通提醒完整回归](runtime-reminder-unit.md)：582/582 通过，0 失败、0 跳过；包含真实 SwiftTerm 重放后同一事项/次数/红点、旧版本已读刷新、分类设置 ACK 和生成 CLI 无 UI 同列表。新增原生语义去重后，原 working 响铃夹具修正为 unknown 兜底；此前 581/582 记录保留。
- 相同 Universal helper 通过[8 项真实提醒检查](runtime-reminder-service.md)、[11 项等待](runtime-reminder-waits.md)、[21 项既有后台回归](runtime-reminder-regression.md)。控制序列不当作响铃/错误，真实响铃合并、命令/进程去重、原生语义审批不与 BEL 双计数；arm64/x86_64 编译、arm64 实际运行。
- [实际 WillDeep + 当前生成 CLI 双等待](native-runtime-reminder.md)：原生审批唯一，所有查看客户端离线 31 秒仍保留同一审批；实际批准后匹配同 task completed，绑定同一 helper 及 rc12 CLI 源 SHA。此前 [BEL 重复事项失败](native-runtime-reminder-initial-failure.md)保留，最终未放宽唯一事项验收。
- 当前仍缺完整项目工具路径、异常退出游标、全布局/多窗口/远端 SSH 及系统通知真实投递验收；正常后台入口关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc11，Build 326

- [后台命令完整回归](runtime-command-unit.md)：572/572 通过，0 失败、0 跳过。含真实 SwiftTerm 同命令身份、生成 CLI 在 UI 停止后等待原命令失败、命令完成不关闭独立 WillDeep 绑定。首轮夹具重复输入错误及修正复验记录在 JSON。
- 相同 Universal helper 通过[11 项后台等待](runtime-command-waits.md)、[21 项既有后台回归](runtime-command-regression.md)、[4 项真实命令退出边界](runtime-command-exit.md)。大量输出后排空真正的结束标记；子进程退出 0 但无标记时仍为未知。事件不包含命令文本。
- [实际 WillDeep 联合复验](native-runtime-command.md)：实际 CLI/隔离 Runtime、本机 mock 模型，全部查看客户端脱离 31 秒后同审批保持，双等待匹配同 task 的 completed；与上述绑定相同 helper SHA。联合用例 CLI 源复用 rc10 导出脚本，SHA 已记录；rc11 当前脚本的命令等待由应用测试覆盖，不冒充完整 GUI 验收。
- 元数据及状态语义见[协议说明](../../RUNTIME_EVENTS_WAIT.md)。普通提醒后台权威、完整项目工具、异常退出游标及全布局/远端 SSH 联合验收仍未完成；后台正常入口关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc10，Build 325

- [后台 CLI/MCP 自动路由完整回归](runtime-cli-unit.md)：564/564 通过，0 失败、0 跳过。实际 UI 工具桥发布服务描述后停止处理/断开查看端；自有元数据模拟 UI PID 退出或代次变化，生成 CLI 仍读取服务状态/事件并等待；MCP ping 继续、取消/EOF 后实际服务等待数为 0。
- [后台等待契约](runtime-cli-waits.md)：10 项通过；[既有后台回归](runtime-cli-regression.md)：21 项通过，与[实际 WillDeep + 生成 CLI 双等待](native-runtime-cli-wait.md)绑定同一 Universal helper SHA。
- 双等待联合通过：实际 WillDeep/隔离 Runtime，本机 mock 模型；原生端点及按当前 Swift 脚本属性生成的 CLI 两个等待在全部查看客户端脱离 31 秒时保持，批准后都匹配同 task 的明确 completed。CLI 源 SHA 已记录。该用例无 GUI 查看端，仅以自有元数据模拟 UI 不在线，不是强杀实际 App 的复验。
- 元数据/权限/路由及服务运行标识见[协议说明](../../RUNTIME_EVENTS_WAIT.md)。后台命令块、普通提醒权威、其余项目工具路径和全部 GUI/远端 SSH 仍未完成；正常入口关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc9，Build 324

- [共享等待完整回归](runtime-wait-unit.md)：559/559 通过，0 失败、0 跳过。UI 与后台复用同一协调器，UI 快照适配、原有命令等待、MCP 并发/取消/EOF 和正常退出清理通过。
- [真实后台事件与等待](runtime-wait-service.md)：10 项通过，包含独立消费者、等待期间查询/报告/真实 PTY 输入继续、所有者与提前取消、容量、超时、服务代次/游标、身份替换和正常服务退出结果。只读文件端点不授予输入权限，输出有独立修订号。
- [既有后台回归](runtime-wait-regression.md)：21 项通过；与[实际 WillDeep 原任务等待](native-runtime-wait.md)绑定同一 Universal helper SHA。等待注册于原审批后，全部客户端脱离 31 秒时仍未命中；实际批准后匹配同一 task 的明确 completed。实际 CLI/隔离 Runtime、本机 mock 模型，纯 PTY 后台用例。
- 协议及权限边界见[后台等待端点](../../RUNTIME_EVENTS_WAIT.md)。通用 CLI/MCP 自动事件路由、后台命令块等待、普通提醒权威和完整项目工具路径仍未完成；正常入口保持关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc8，Build 323

- [后台 Agent 工具完整回归](runtime-agent-tools-unit.md)：558/558 通过，0 失败、0 跳过。真实工具桥/Socket/原生状态端点共用同一监视器及待处理；停止 UI 请求处理和查看端后，实际生成 CLI 仍可通过私有绑定端点上报。首轮 1 项恢复夹具就绪失败及后续就绪屏障修正保留在报告中。
- [新增 Agent 工具契约](runtime-agent-tools-service.md)：7 项通过，包含状态凭据不可授权 UI/输入 Socket、跨终端及迟到代次拒绝、重复序号拒绝、唯一审批/完成和重新绑定废除旧凭据。
- [既有后台回归](runtime-agent-tools-regression.md)：21 项通过；与[实际 WillDeep 后台联合验证](native-agent-tools-backend.md)绑定同一 Universal helper SHA。实际 CLI/隔离 Runtime 使用本机 mock 模型，全部客户端脱离 31 秒后原 PTY/前台进程/审批保持，实际确认后完成；这是纯 PTY 后台用例，未重做全部 GUI。
- 协议 3 增加 `agent_tools_v1` 能力声明；未知能力明确拒绝且不使既有查看端断连。后台绑定不取决于终端写入开关，不授予输入租约；UI 不再创建本地第二份状态。新绑定的后台端点失败不回退 UI 权威，旧绑定保持旧路径，报告时间继续以 RFC3339 公开。
- 仍需通用事件读取/等待、普通提醒的服务权威、完整项目工具路由，以及非正常退出/全部布局/多窗口联合验收和远端 SSH；正常入口继续关闭，未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc7，Build 322

- [孤立会话恢复完整回归](runtime-orphan-unit.md)：554/554 通过，0 失败、0 跳过。真实后台缺失记录时原 PTY 可继续输入；两窗口并发发现不重复认领，未打开记录里的终端仍保留，损坏文件不覆盖；无服务时不通过发现流程启动后台。
- 配置来源无法证明的后台终端明确标为“仅附着”，沿用原 UUID/代次，不猜测 SSH/Profile 或重发启动命令；正常保存退出后仍可按身份恢复。手动配置快照与继承配置分屏不接受这种未知来源，避免将远端错误重建成本地 shell。
- [记录缺失后找回真实 WillDeep 审批](native-orphan-recovery.md)：通过。正常退出后仅暂移 QA 唯一恢复记录，确认界面消失至少 46.35 秒；重开自动找回同 PTY/PID/代次、同 WillDeep/task/gate/审批 ID，后台和 UI 各只有原终端。真实批准后生成唯一完成事项；新保存的仅附着记录再次重开仍接回原 shell。该场景不是强杀 App 或后台崩溃重建测试，缺失的原布局/Profile 不会被猜测还原。
- 仍需完整工具/事件路由、远端 SSH 及全部布局/多窗口验收。正常产品入口仍关闭，未提交、未发版、本机应用未替换。

## 前一阶段：1.251.0-rc6，Build 321

- [SSH 重连完整单元回归](runtime-restart-unit.md)：549/549 通过，0 失败、0 跳过。新增真实 PTY 新代次/启动恰好一次、实际 ssh 手动重连和自动重连上限；SSH 目标为保留但不监听的本机随机端口，不是远端认证成功或网络断开复验。
- [已退出 PTY 安全重启](runtime-restart-service.md)：同一 Universal helper 的 8 项真实 Socket/PTY 检查通过，包含失败保留、迟到身份拒绝、活动进程拒绝与跨 Socket 丢 ACK 去重。
- [后台既有完整检查](runtime-restart-service-regression.md)：21 项通过；与上一项绑定同一 helper SHA，arm64/x86_64 两种架构均完成编译，本机运行测试为 arm64。
- 新 UI 仅在后台声明 `restart_exited_v1` 能力后发送重启；没有声明时明确拒绝，不重启旧服务。正常恢复仍接回原代次并跳过启动命令。该能力检测已实现，真实旧服务的重启拒绝 GUI 场景尚未专项复验。
- 仍缺：孤立会话发现、完整工具/事件路由、远端 SSH 认证/网络故障和多窗口/全部布局联合验收；正常后台入口继续关闭。未提交、未发版、未替换本机应用。

## 前一阶段：1.251.0-rc5，Build 320

- [回放边界与初始尺寸完整回归](runtime-replay-unit.md)：546/546 通过，0 失败、0 跳过；包含历史/实时同帧分段、已显示游标私有恢复、真实 SwiftTerm 静默历史、脱离期间新响铃保留，以及首次连接后实际 `stty size` 核验。
- [真实原审批恢复与完成](native-replay-recovery.md)：QA 界面进程确认消失至少 199.19 秒后，最新查看端接回原服务/PTY/WillDeep/task/gate；实际 UI 总待处理只有 1 条原审批，批准后只有 1 条完成事项，未出现历史响铃。查看器和后台实际尺寸均为 74×31，审批和完成画面未再观察到此前错位。本机 mock 模型，正常产品入口仍未启用。
- 修正此前定位：文字错位在退出前已存在，当时查看器 74 列、后台 75 列；初始布局早于后台就绪，尺寸更新被跳过。不能把它全部归为历史恢复问题。
- 尚待：SSH 重连、孤立会话发现、工具与事件全路径、全部多窗口/布局验收和正常产品入口。未提交、未发版、未替换本机应用；没有已显示游标的旧恢复记录仍沿用旧行为。

## 前一阶段：1.251.0-rc4，Build 319

- [剪贴板修复完整应用回归](runtime-clipboard-unit.md)：541/541 通过，包含实际暂停主线程 7 秒、PTY 继续输出后保持原连接/PID/代次。
- [旧 helper 反向对照](consumer-pause-before.md)与[修复后对照](consumer-pause-fixed.md)：同 Socket、同 7 秒暂停和 100000 字节负载，旧实现触发 5 秒 write_deadline 并丢失尾部，修复后完整接收 100020 字节，无异常断开。
- [后台完整检查](runtime-clipboard-service.md)：21 项通过，保留积压容量限制和慢消费者隔离；新增私有诊断的权限、脱敏及 32 条记录上限验证。
- [真实剪贴板提交与审批恢复](native-clipboard-recovery.md)：粘贴提交后无需手动重连，正常进入审批；界面退出至少 67.87 秒后重开仍为原 PTY/前台 PID/同一 task/gate，实际确认后完成。后台没有异常断开记录，本机 mock 模型。
- **整体 UI 验收仍未通过**：已在全新单终端 QA 确认回放历史响铃产生额外“终端响铃”事项，不能归因于其他旧终端；恢复画面也有历史绘制残留。原生审批唯一性与界面总列表正确性分别验收，正式后台入口保持关闭。

## 前一阶段：1.251.0-rc3，Build 318

- [真实 WillDeep 图形重开与逐键审批](native-real-gui-keyboard.md)：通过。原生 QA 界面退出至少 69.51 秒后重开，同 PTY/代次、同前台 WillDeep PID、同 task/gate 和唯一审批事项保持；真实按 y 后同任务产生唯一完成摘要。实际 QA 是 rc2/Build 317，本机 mock 模型；剪贴板和恢复画面的完整正确性仍未通过。
- [项目菜单、移动与分屏](native-project-menu.md)：rc3/Build 318 隔离 QA 的完整和紧凑行菜单均可见；实际项目移动保持原 PID/代次并可继续输入，通过菜单新建分屏后输入只到新叶子。显式关闭旧夹具后后台移除 PTY、布局收缩，其余会话保留。布局与恢复专项 20/20 通过。
- [完整应用单元回归](runtime-diagnostics-unit.md)：rc2 的 540/540 通过，使用隔离 GoalTests.QTerm4 宿主；rc3 目前为上述 20 项专项与原生菜单复验，此前 536 项记录为历史结果。
- [原生 App 退出重开](native-app-relaunch.md)：Computer Use 操作隔离 QA，验证原 PTY/输出标记/分屏、跨 QA 界面副本的同服务与四个 PTY、悬浮身份及新分屏实际目录。它补齐了普通 shell 的真实 App 退出重开证据；下面历史 XCTest UI runner 的超时记录仍保留。
- [早期 WillDeep 图形联合复验](native-willdeep-gui.md)：两轮历史失败保留。第三轮逐键路径已取得恢复/确认成功证据；第四、五轮剪贴板失败的后续诊断确认为订阅误用 RPC 写超时，见上面的 rc4 修复与实际粘贴重验。原始字节记录器及 crossterm 0.29 异步最小程序排除了基础字节解码路径。
- [验收驱动原后台模式回归](native-driver-regression.md)：通过，原 PID、进程代次、前台 WillDeep PID 和唯一审批事项在全客户端脱离 31 秒后保持，再确认完成。该项使用纯 PTY 驱动，仍不代替 GUI 输入路径。
- 断连后输入失败现在保留“重新连接”入口；工具 `runtime.errorCode` 提供脱敏错误码。正式后台入口仍未启用，本机安装包仍为 rc1/Build 314。

## 历史阶段记录

本轮为 `1.251.0-rc1` / Build 316 的未提交开发；未发版、未安装、未重启用户本机 QTerm 或正常 WillDeep Runtime。完整目标仍未完成。

## 当前证据

| 路径 | 已核验结果 | 边界 |
|---|---|---|
| Rust `qterm::` 单测 | 16/16 通过 | 含任务归属、权限文件、最终状态发送；不是 UI 联调 |
| QTerm 原生状态、项目布局、输出缓冲 | 18/18 通过 | `/private/tmp/qterm-runtime-output-native-layout-01.xcresult` |
| 拆分后的终端宿主编译及输出缓冲 | 5/5 通过 | `/private/tmp/qterm-host-transport-split-01.xcresult`；此轮未选中输入法测试 |
| 输入法 Return 两项专项回归 | 2/2 通过 | `/private/tmp/qterm-host-ime-regression-01.xcresult`；复用拆分后的构建 |
| 实际 WillDeep TUI/Runtime 跨进程 | 通过 | 见 `native-tui.json`；mock 模型及状态桥，不是真实 QTerm 桥联合验收 |
| 实际无头 CLI 完成/待审批 | 两种均通过 | 见两份 `native-headless-*.json`；命令退出不发送 exited 清除 Runtime gate |
| 分屏 UI XCTest | runner 初始化超时 | 未执行用例，不能记为通过；`qterm-project-ui-01/02.xcresult` |
| 独立后台持有真实 PTY | 服务已实现、跨进程通过 | 见 `runtime-service.json`；尚未接入正常 QTerm 界面与安装路径 |
| 生产 Swift 后台连接器 | 跨进程通过 | 见 `runtime-swift-client.json`；尚未连接 NSView/产品恢复逻辑 |
| 实际 WillDeep + 实际后台 | 跨进程通过 | 见 `native-real-backend.json`；全部 UI 客户端断开 31 秒，同 PID、同审批事项，确认后完成 |
| 共用模型与连接器在应用目标内 | 43/43 专项通过 | `/private/tmp/qterm-shared-runtime-client-models-02.xcresult`；后续连接器小幅收紧边界另由生产连接器探针验证 |
| SwiftTerm / 产品控制 / MCP 等待专项 | 18/18 通过 | `runtime-view-control.json`，含原 PID 重连、产品接管/续租/人工收回、输入 ACK；后续静默首包修复另行验收 |
| 完整应用单元测试 | 517/517 通过 | `runtime-app-unit.json`，含实际工具桥权限拒绝、接管、输入执行、释放和旧输入拒绝；不是 UI 自动化 |
| 协议 2 后台含静默修复 | 18 项跨进程检查通过 | `runtime-service-heartbeat.json`，含续租向其他查看端广播、15 秒无输出心跳、慢消费者断开 |
| 实际 WillDeep + 静默修复后台 | 通过 | `native-real-backend-heartbeat.json`，与上一行绑定同一 Universal helper SHA；全客户端断开 31 秒、同 PID/gate、确认后完成 |
| 当前 embedded helper + 真实窗口 | 7/7 通过 | `runtime-idle-view.json`；含静默 6 秒后的首包、原 PID 重连、设备回复、控制和真实工具桥 |
| 退出恢复接线后完整应用单元测试 | 530/530 通过 | `runtime-restore-unit.json`；含真实窗口/PTY 保存后重连，不包含完整 App 退出重开 UI 自动化 |
| 最新恢复记录与真实窗口专项 | 20/20 通过 | `runtime-recovery-private.json`；脱敏、待挂载面板、缺失会话拒绝替代、保存失败原窗口继续输入、启动命令不重放 |
| 协议 3 输入/控制/传输相关专项 | 64/64 通过 | `runtime-input-safety.json`；真实预检、echo 切换拒绝、批准/ACK、取消、恢复后隐藏输入私有存档；传输部分含已有相关回归 |
| 当前完整应用单元回归 | 536/536 通过 | `runtime-input-unit.json`；不是完整 UI 端到端 |
| 当前协议 3 Universal 服务 | 20 项检查通过 | `runtime-service-input-v3.json`，含真实 echo/前台校验、维护退出只允许空服务、保活与慢消费者 |
| 实际 WillDeep + 当前协议 3 服务 | 通过 | `native-real-backend-input-v3.json`；同 SHA、全客户端断开 31 秒后同 PID/gate 并确认完成 |
| 完整 App 正常退出重开 UI | 未执行 | `runtime-app-relaunch-ui.json`；runner 初始化启用自动化模式超时，不能记为通过 |

前面的服务/连接器/实际后台报告保留为早期协议证据，不能用来证明后续代码。当前后台最新证据是 `*-heartbeat` 两份报告；应用完整单测后新增的静默首包窗口用例单独记录，不能把历史单测数量相加当作一次全量通过。

实际 CLI 测试由 `scripts/verify_willdeep_native.rb` 运行：临时私有 home/工作区、显式创建并回收的 Runtime 子进程、本机 mock 模型、PTY 和私有状态文件桥。状态凭据及终端正文不进入报告。TUI 测试覆盖丢失一次审批 ACK、递增序号重试、30 秒心跳、审批前后同一 task/gate 归属及完成不误报中断。

## 失败与修复

- 第一版测试清理中的通用 `daemon stop` 被自动审批拒绝；已去掉，改为仅回收脚本创建并经 waitpid 验证的子进程。
- 临时目录过长导致 Darwin Unix socket 无法绑定；改用 `/private/tmp` 下的短私有目录。健康检查路径及认证头已按源码修正。
- 早期实际 TUI 记录到最终完成前对合成任务上报 interrupted；改为以 local_mode 判断本地任务结束，新增单测和实际运行反误报断言。旧第六轮报告不能作为完整通过证据。
- 一项传输单测读到了夹具响应文件的半截 JSON；夹具改为原子发布后 16 项全部通过。
- 无头待审批首轮被 Runtime 默认工作区写入策略直接放行；测试改为显式注册 strict 临时工作区后，获得真实待审批 gate 并验证命令退出后状态未被清除。没有改动正常工作区策略。
- 实际后台联调最初不处理首批键盘输入：进程采样和 `ratatui-image` 源码确认，探测线程在未收到 DSR 响应时仍可能读取 stdin，与 TUI 竞争。纯 PTY 驱动补上标准设备状态响应后联调通过；不以屏幕出现 Ready 代替终端协议响应。界面接入时必须保留 SwiftTerm 的设备查询回复路径。
- Swift 连接器探针首轮把 shell 回显中的 marker 当作已执行，过早断言 echo-off；判据改为完整输出行后通过。没有放宽 echo-off 断言。
- 实际 SwiftTerm 窗口首轮恢复输出判据受到无回显 shell 提示符粘连影响；测试命令显式输出前置换行后验证完整输出行。设备回复实际已收到，`od` 的多空格让原固定空格断言误报；按十六进制 token 验证完整四字节回复后通过。
- 静默订阅心跳新增回归暴露实际服务错误：静默时间被用作首个待发送包的写超时起点。改为队列从空变为非空时计时，仍保留积压上限与真实慢消费者断开；新版完整服务回归通过。
- 全量单测第一轮 515 通过、1 失败：旧安装器测试假定测试宿主使用生产 Tools 目录。隔离宿主已改私有 root，断言改为验证生成 CLI 的正式 ROOT 路径，第二轮 517 全通过，包含新增实际工具桥测试。

## 独立后台本轮证据

`scripts/build_terminal_runtime.rb` 已构建 arm64/x86_64 Universal 可执行程序，三个新报告绑定同一后台 SHA256。未签名发布、未安装、未启动用户生产后台。

最终连接器边界修正后，隔离 Bundle ID 的 QTerm 应用目标再次构建成功。本机安装包回读仍为 `1.250.0-rc1` / Build 314；开发版本 `1.251.0-rc1` / Build 316 尚未安装。

- 服务入口显式指定私有 root；Unix socket 0600、目录 0700、peer UID 校验、独占锁与私有 UI capability。WillDeep 的 bootstrap/grant 只进状态文件端点，不能调用输入 socket。
- 实际客户端进程退出后原 PTY、PID 和持续输出保留；重连可输入、调整真实 PTY 大小。明确关闭只影响目标终端，并验证测试子进程已消失。
- 输入 request ID 缓存和控制代次内递增序号防重复；人工收回控制拒绝旧 AI 请求。真实 termios echo-off 在输入响应中返回，排队或未知 echo 不允许当作可记录明文。
- 输出按进程代次与字节游标回放，有界缓冲明确报告缺口；订阅、慢消费者断开、超大帧拒绝、启动参数上限及 exec 失败不影响其他活会话。
- 事件、Agent 与待处理使用从应用中拆出的同一套模型；UI 连接全部关闭时原生状态端点继续工作。已读审批保留、连续 gate 不合并、完成摘要去重，事件不携带能力凭据。
- Swift 连接器覆盖实际握手、同 PID 重连、echo-off 输入、输出游标、发送前帧上限、跨执行器取消不杀 PTY，以及 capability 符号链接拒绝。

## 剩余验收

SwiftTerm/NSView 外部传输、helper 打包、服务发现、产品控制和输入 ACK 已进入隔离宿主验证。正常产品后台默认启用、应用退出与保存恢复同 PID、输入安全 echo 预检、Agent/普通提醒与事件等待路由统一仍未完成；项目分屏实际 UI、焦点、悬浮归属和工具动作仍待实现/验收。还需旧服务兼容不强制重启与三块图形界面联合验证。详情见上级实施方案。当前服务通过不代表已安装 QTerm 已能退出保活。

退出保存与原身份恢复已接入应用方法并获得真实窗口/PTY 验证，悬浮项目归属和恢复记录也已实现。仍缺完整 App 退出重开、多窗口和悬浮恢复的实际 UI 证据，以及后台默认启用前的输入安全、审计、SSH 重连、孤立会话发现和完整工具/事件路由。当前证据不能据此宣称全部目标或已安装应用具备这些能力。

最新协议 3 已补输入预检、写前上下文拒绝、恢复后私有存档，并完成上述当前回归；早期协议 1/2 服务报告仅保留为历史阶段证据。完整 UI 用例尚未进入执行，替代原生启动入口还需测试配置；输入确认与可信传输完整端到端、SSH 重连、孤立会话发现、工具/事件全路径和完整图形联合验收仍待完成。当前已安装版本仍为 `1.250.0-rc1` / Build 314。
