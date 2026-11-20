# 当前界面连接实际旧驻留后台

日期：2026-10-24。当前 UI：1.251.0-rc18 / Build 333；实际驻留后台：1.251.0-rc5，协议 3，没有可选 features 声明；隔离 WillDeep CLI：0.115.0-rc1。

结果：同协议旧后台兼容主路径通过。本轮没有修改产品源码，沿用此前完整 605/605 构建，没有重新声称运行全量测试。

## 原终端与能力边界

1. 在全新私有 QA 根中启动保留的真实 rc5 helper，先创建真实 /bin/sh PTY；记录 helper 完整路径、PID、SHA、hello 版本/服务 epoch 和终端 UUID/PID/代次。没有连接或清理之前遗留的其他 QA 后台。
2. 再打开当前 rc18 QA App。当前界面发现同一旧服务及原终端，显示“仅附着（原配置缺失）”，分屏按钮禁用，未猜测 Profile 或重发启动命令。
3. 原生输入 printf 组装完整 FIRST 标记，实际输出正确；UI 和后台只有原终端，身份匹配。当前嵌入 helper 没有取代驻留 rc5 进程。
4. 旧后台未声明事件等待等新能力，当前 runtime.json 没有发布 backend 事件端点。通过私有只读 UI 工具桥请求 get_agent_state，明确返回 unsupported_feature，没有向旧服务发送未知 Agent 工具操作，也没有静默切换状态权威。
5. 正常退出新界面，核验 UI PID 消失、旧服务及原 PTY 保持；确认 UI 不在并等待 31 秒后重开，再原生输入 SECOND 标记，原进程和输出保持，UI epoch 改变而服务 epoch 不变。

## 实际 WillDeep 审批与强制结束

- 在同一个旧后台原 PTY 内，用原生界面启动当前隔离 WillDeep CLI/私有 Runtime，以本机 mock 模型产生严格审批。当前 UI 显示 WillDeep 等待处理、唯一审批事项和项目聚合 1。
- 记录原 WillDeep 前台 PID、实例/run、session/task/gate、审批 ID 和已保存解析检查点；核对完整 QA UI 可执行路径后，仅向当前隔离 UI 发送 SIGKILL。
- 在 UI 已消失且尚未重开的时点，核验离线至少 51.700 秒；原 rc5 服务、PTY、WillDeep 前台、任务及唯一审批保持。重新打开 rc18 UI 后只恢复原审批，没有重建或重复事项。
- 原生按 Y 一次性批准 `printf qterm_native_probe`，后台和 UI 同步生成唯一同 task 完成事项；实际点击查看后，两者均清零。输入 /exit 后实际 CLI 显示已退出，驱动 passed=true。
- 最后退出 QA，核验当前 UI 不在、旧 helper 完整路径/PID/hello 仍为 rc5；只关闭本轮唯一 PTY 和空旧后台，均已退出。正式 QTerm 和正常 WillDeep Runtime 没有变更。

## 证据与限制

- [驻留服务与实际身份验证](old-backend-compatibility.json)：全部版本、PID/代次、原生输入标记、只读缺失能力错误、强制结束前/离线/恢复后/完成的实际状态，以及清理结果。
- [原生 CLI 驱动原始报告](old-backend-native-driver.json)：真实隔离 WillDeep/Runtime、本机 mock 模型及审批到完成状态。该通用 qa-ui 驱动的 qtermBackendSHA256 字段是 **QA App 内嵌的候选 helper**，不能当作本轮实际驻留 helper。二者在主报告分别标注；实际驻留进程通过独立 PID/完整路径/版本/SHA 验证，未修改原始驱动字段来掩盖差异。
- 实际 rc5 helper SHA256：`e9c23bedc86823b1cd85a57f5febc8c747c11c7077050a6bde454da30f284c14`。当前候选内嵌 helper SHA256 另存主报告；它未用于替换旧服务。
- 普通退出的 uiAbsentSeconds 原始字段包含重开及输入观察延迟，因此只声称确认离线等待 31 秒；强制结束的 offlineSeconds 在重开前直接核验，可作为至少 51.700 秒的离线证据。
- 私有探针 `/private/tmp/qterm_old_backend_probe.rb`、`/private/tmp/qterm_native_crash_probe.rb`；QA 元数据 `/private/tmp/qterm-native-qa-5ad9607b8fba/qa.json`。CUA 实际观察表单/审批/事项；未保存 PNG。

该证据仅覆盖一个真实同协议 rc5 旧服务：不让旧服务冒充拥有新能力，也不证明旧服务获得新的 1 MiB 响应预算。不兼容协议、损坏端点、其他旧版本和旧服务大容量边界仍需验证。完整项目工具 GUI、多窗口/全布局/悬浮/英文/窄窗口、长标题快捷键、远端 SSH 和系统通知仍待收尾；正常后台入口继续关闭，未提交、未发版、未替换本机应用。
