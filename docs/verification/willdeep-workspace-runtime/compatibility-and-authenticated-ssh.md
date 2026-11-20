# 损坏端点拒绝与真实 SSH 认证/断连验收

版本：1.251.0-rc24 / Build 339。正常后台入口仍关闭；未提交、未发版、未替换本机 QTerm 或正常 WillDeep Runtime。

## Swift 客户端故障边界

新增 `TerminalRuntimeCompatibilityTests` 使用实际嵌入 helper 和真实 PTY，再用私有 Unix socket 代理定向损坏服务响应。五种故障分别验证：

- 不兼容协议 → `incompatible_protocol`。
- 非法 JSON 响应、请求身份不符 → `invalid_response`。
- 超过响应预算 → `frame_too_large`。
- 同一连接的服务代次变化 → `service_changed`，连接关闭，不能继续使用。

构造连接失败时，`ensureRunning` 必须直接返回原错误，不能转入替代启动。代理请求记录只有 hello，或代次用例中的 hello/list，没有 create/input/close。每个用例在故障之后读取真正后台，核对原终端 UUID/PID/代次仍在，并执行命令看到独立结果行；因此不是只断言错误枚举。

定向 **5/5**、完整 **616/616，0 失败、0 跳过**。见 [定向结果](compatibility-targeted-unit.json)、[完整回归](compatibility-full-unit.json)。这是受控损坏端点和当前真实后台验收，不冒充五个真实历史版本；此前实际 rc5 兼容证据仍见 old-backend-compatibility.md。

## 真实 SSH 后台路径

`scripts/verify_runtime_ssh.rb` 配合 `scripts/support/runtime_ssh_fixture.rb` 启动只监听 127.0.0.1 的临时 OpenSSH 服务及自有 TCP 中继。使用一次性 ed25519 密钥、显式授权文件、严格固定主机密钥、StrictModes、禁用密码/转发策略，不启用系统远程登录、不读写用户 `~/.ssh`。

实际 QTerm helper 创建 SSH PTY，10 项检查通过：

1. 公钥认证并执行实际远端 shell。
2. 查看客户端退出再连接，SSH 原 PID/代次保持。
3. 重新附着后命令实际执行。
4. 关闭自有 TCP 连接模拟真实传输断开，原 SSH 退出 255，原终端身份保留，没有隐式替换。
5. 显式 restartExited 在同终端 UUID 下产生新 PID/代次，重新认证并执行命令。
6. 旧代次的迟到重连被拒绝，不能替换仍在运行的新 SSH。
7. 错误主机密钥明确出现 Host key verification failed，退出 255，不自动接受。
8. 错误身份密钥明确出现 Permission denied (publickey)，退出 255，不绕过认证。
9. 两种负向认证用例之后，原重连会话的 PID/代次仍相同且能执行命令。
10. 仅关闭本轮 PTY，空后台退出；临时监听、中继线程和密钥目录全部回收。

见 [真实 SSH 结果](authenticated-ssh-service.json)，helper SHA 为 `9c877f1c4b8cf65de020d0068938d119d80631a9c965f62251954892ec399c96`。运行命令：

```sh
ruby scripts/verify_runtime_ssh.rb /absolute/path/to/qterm-runtime /private/tmp/qterm-authenticated-ssh
```

首个可行性夹具把授权文件放在 `/private/tmp`，OpenSSH 因该父目录可写而拒绝；脱敏记录见 ssh-authentication-initial-feasibility.json。最终将授权文件移到所有父目录权限合规的私有工作区 `.qssh-fixture-*`，保留严格检查。该前缀已加入 `.gitignore`，脚本成功和失败都会清理，不提交密钥。

另外故意把 helper 换成立即退出的 `/usr/bin/true`：验证器按预期失败，但 SSH 服务、密钥和目录仍清理完成。见 [失败清理负向验证](authenticated-ssh-cleanup-negative.json)。最终未留下 `.qssh-fixture-*` 目录。

## 范围限制

SSH 结果是回环真实协议、认证和网络断连，尚非外部机器或完整 GUI/SSH Profile 的认证、输入、恢复联合验收。正常应用的正式启用、更多布局/窗口、系统通知真实投递，以及原 rc21 偶发重启输入未获 ACK 的根因继续推进。
