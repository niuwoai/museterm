# MuseTerm SSH Experience Plan

> 最后更新：2026-07-01
> 当前阶段：SSH Profile 从“保存连接参数”升级为“远程工作台体验层”。

## 北极星

MuseTerm 的 SSH 管理不应只是替用户记住 `user@host -p 22`，而要把远程连接中最常见的麻烦提前消化掉：空闲断线、跳板链路不透明、端口转发难记、密钥和主机指纹风险难判断、连接失败原因难读。

## P0：连接稳定与速度

- 已落地：协议层保活，默认生成 `ServerAliveInterval 30` 与 `ServerAliveCountMax 6`。
- 已落地：连接复用，默认生成 `ControlMaster auto`、`ControlPersist 10m` 与独立 `ControlPath`，让同一主机的新标签页更快打开。
- 已落地：保守自动重连，断线后保留标签页并在终端展示轻量倒计时；仅对疑似临时断线有限重试，认证失败、Host Key 变化和认证身份过多不会自动重连。
- 下一步：增加手动重新连接按钮，让用户在自动重试停止后无需新建标签。
- 下一步：进一步区分服务端主动断开、网络抖动和用户主动退出。

## P0：端口转发工作流

- 已落地：Profile 支持结构化端口转发，覆盖 `LocalForward`、`RemoteForward` 和 `DynamicForward`。
- 已落地：存在结构化端口转发时自动生成 `ExitOnForwardFailure yes`，避免端口冲突或转发失败悄悄被吞。
- 下一步：把文本格式升级为表格化编辑器，按“本地端口、远端目标、SOCKS 代理”分类展示。
- 下一步：连接成功后展示可点击入口，例如 `localhost:8080` 或 SOCKS 代理地址。

## P1：跳板机可视化

- 当前能力：Profile 已支持多跳 `ProxyJump`，并支持每一跳单独配置用户、端口和密钥。
- 下一步：在侧栏 tooltip 和编辑器里展示“本机 -> 跳板 1 -> 跳板 2 -> 目标机”的链路摘要。
- 下一步：增加逐跳测试，明确告诉用户是 DNS、端口、认证还是 ProxyJump 失败。

## P1：安全护栏

- 当前能力：Profile 已区分开发、预发、生产环境，并可为生产环境强制高危操作确认。
- 下一步：Host Key 首次连接/变更时给出明确风险说明和修复引导。
- 下一步：`ForwardAgent` 开启时提供明显提示，避免把本机 agent 暴露给不可信远端。
- 下一步：私钥权限过宽时提示 `chmod 600` 修复命令。

## P2：配置导入与双向同步

- 下一步：从 `~/.ssh/config` 导入 Host，保留原始别名、用户、端口、密钥、跳板和常见转发规则。
- 下一步：MuseTerm 编辑后的 Profile 可选择导出为 OpenSSH config 片段，但默认不覆盖用户原文件。
- 下一步：支持 Profile 分组、搜索和标签，例如个人服务器、公司内网、云主机、临时机器。

## P2：智能诊断

- 已落地：终端输出旁路识别常见 SSH 失败，并追加 MuseTerm 提示，覆盖认证失败、Host Key 校验失败、连接超时、连接被拒绝、认证身份过多和端口转发失败。
- 下一步：解析 SSH stderr 常见错误并给出面向行动的建议：
- `Permission denied`：检查用户名、密钥、`IdentitiesOnly` 或 agent。
- `Host key verification failed`：解释风险，提供 known_hosts 定位与清理引导。
- `Connection timed out`：建议检查端口、防火墙、VPN、跳板链路。
- `Too many authentication failures`：建议启用 `IdentitiesOnly yes` 或指定更少密钥。

## 验收原则

- 每项能力必须能在生成的 OpenSSH config 中被测试验证。
- 默认行为应提升稳定性和速度，但不能覆盖用户在高级选项中手写的同名 OpenSSH 配置。
- 新增可见文案必须走本地化资源。
- 任何可能改变安全边界的选项都需要明确提示，而不是藏在高级参数里。
