# 最大会话元数据响应容量

日期：2026-10-24；最终版本 1.251.0-rc18 / Build 333。

## 复现与修复

修复前，普通 930 字节目录、64 个真实 PTY、每会话 8 个命令投影及最大长度 Agent task/gate 上下文，响应约 253 KB，可以读取。相同长度目录含合法引号时，JSON 转义使第 56 个会话的列表超过旧 256 KiB 发送队列，实际客户端收到 EOF。原始结果见[修复前报告](runtime-capacity-before.json)。首次夹具缺少必需 PTY 尺寸导致 0 会话解码失败，已补字段后重新运行；该夹具错误不作为产品缺陷。

现在请求上限仍为 128 KiB，PTY 输出分块仍为 64 KiB；响应与请求分开限制，单响应限 1 MiB，每客户端待发送队列限 2 MiB。Swift 连接器与服务共用响应预算。超过响应预算时返回保留 serviceEpoch、请求 ID/action 的 response_too_large 错误，不返回部分会话，不以 EOF 掩盖。启动目录也在 fork 前按系统 PATH_MAX 校验。

队列上限增加后，慢消费者测试同步改用 4 MiB 真实输出，确保超过新队列容量，以实际回压断连验证 PTY 和快消费者继续运行，而非等待 30 秒超时冒充回压验收。

## 当前证据

- [定向和完整回归](runtime-capacity-unit.json)：3/3、605/605，0 失败、0 跳过。包含真实 Swift 连接器读取 64 个控制字符长目录 PTY 的完整元数据，以及超大响应的明确错误与身份保持。
- [引号路径容量](runtime-capacity-escaped.json)：64 个真实 PTY、8 个命令/终端、完整原生 Agent 上下文；实测最大帧 309251 字节。
- [控制字符路径容量](runtime-capacity-control.json)：同样 64 个真实 PTY；最坏字符转义实测最大帧 534503 字节。
- 两组容量脚本均核验 UUID/PID/代次、目录、running、Agent 活动和两个最大上下文字段完整一致；第 65 个会话返回 resource_limit，原 64 个身份保持。测试 PTY 和自有空后台均回收。可通过 `ruby scripts/verify_runtime_capacity.rb HELPER REPORT_PREFIX escaped` 或 control 重现，输出 JSON/Markdown。
- 同一 Universal helper 的[21 项既有后台回归](runtime-capacity-regression.md)、[11 项等待](runtime-capacity-waits.md)、[8 项提醒](runtime-capacity-reminders.md)通过，含增大有界队列后的慢消费者回压、游标/取消和语义提醒去重。
- [真实 WillDeep + 当前生成 CLI](native-runtime-capacity.json)：实际隔离 CLI/私有 Runtime、本机 mock 模型，全部查看端断开 31.002 秒仍保留唯一原审批；批准后原生端点和 CLI 两个等待均匹配同 task completed。

上述独立后台用例的 Universal helper SHA256 均为 `4ecba0b98b1ff28a04912a345029379cb944e4ebf5f075d40c5b1b6d24ec8c71`，包含 arm64/x86_64，本机运行 arm64。生成 CLI 源 SHA 单独保存在 WillDeep 报告，未安装。

## 边界

容量用例中的 Agent 报告是协议夹具，不冒充 64 个真实 WillDeep 并发；真实 CLI 由单独联合报告验证。本轮没有重做完整 GUI，也没有证明旧驻留后台可以获得新预算；不会为升级后台强制关闭已有会话。旧服务兼容、完整项目工具 GUI、多窗口/全布局、英文/窄窗口/悬浮、长标题快捷键显示、远端 SSH 和系统通知仍待验收。正常后台入口继续关闭，未提交、未发版、未替换本机应用或正常 WillDeep Runtime。
