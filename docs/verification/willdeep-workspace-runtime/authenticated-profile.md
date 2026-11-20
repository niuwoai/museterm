# 真实 SSH Profile 与 SwiftTerm 控制器联合回归

Profile 阶段：1.251.0-rc25 / Build 340。后续 rc26 启用普通后台入口的完整结果另见 runtime-default-full-unit.json。

使用私有回环 OpenSSH、固定主机密钥、一次性身份密钥和受控远端 shell。测试经过真实 `SSHConnectionProfile`、配置生成、终端控制器、SwiftTerm 和后台/PTY，不伪造认证成功。测试窗口为 AppKit 离屏窗口，不能冒充完整应用的鼠标/菜单验收或外部服务器验收。

## 最终结果

定向 **3/3**，完整 **619/619，0 失败、0 跳过**。见 [定向](profile-final-targeted-unit.json)、[完整](profile-full-unit.json)。

1. 手动路径从已退出的原代次使用 Profile 重新认证，启动命令实际输出远端 shell PID。脱离查看器后，新查看器接回原 PID/代次，不调用启动回调；真实输入成功。实际 TCP 关闭后，显式重新连接创建新 PID/代次及新远端 shell，仍能输入。
2. 自动路径从真实 Profile 配置建立 SSH；TCP reset 后自动重新认证，原终端 UUID 保留，新的 PID/代次和启动命令实际执行。第二次 reset 后重试预算耗尽，后台仍保留同一个已退出代次，没有继续创建新进程。
3. 启用自动重连但提供错误固定主机密钥时，真实 SSH 明确拒绝，等待超过配置的重试延迟后，UI 和后台仍为原已退出 PID/代次，没有自动重试认证。

测试生成的 Profile 使用随机 UUID 配置文件，用后删除该文件，不改既有 Profile。私有 SSH 服务、密钥目录及控制管道均清理，最终没有 `.qssh-fixture-*` 目录。

## 初始失败和修正

- [首轮](profile-initial-unit.json)：手动路径通过，自动路径错误地使用 FIN 正常关闭，实际策略识别为远端主动关闭并停止。这是正确的保护策略，产品没有为通过测试放宽它。随后将自动场景改为真实 TCP reset。
- [第二轮](profile-reset-cleanup-unit.json)：手动/自动行为断言通过，但自动用例的夹具退出等待超时。复核时服务和密钥已清理；后来用明确的 stop/ack 控制消息代替仅依赖 stdin EOF，保留原退出等待上限，并采集失败清理错误。
- 第三轮两项通过，随后补充真实主机密钥失败禁止自动重试，最终三项均通过。全部失败记录保留，没有延长测试时间或绕过认证来取得最终结果。

回环服务保留 StrictModes、严格主机校验和禁用密码/转发；没有启用系统远程登录，没有修改 `~/.ssh`，未访问正常 Runtime。
