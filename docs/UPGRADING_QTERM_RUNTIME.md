# 升级与终端会话保留

## QTerm 更名为 MuseTerm

从 `1.256.0-rc2` 起，应用为 `MuseTerm.app`，命令与 MCP 服务名为 `museterm`，Homebrew 安装使用 `brew install --cask niuwoai/tap/museterm`。已有 MCP 客户端请把命令改为 `~/.local/bin/museterm`，并在应用设置中安装新版 CLI。

Bundle ID 仍为 `im.some.museterm`，偏好、SSH Profile 与钥匙串服务保持连续。新安装使用 `Application Support/MuseTerm`；若对应的新目录尚不存在，则继续使用旧 QTerm 的 Tools、Runtime 或 LearnedCommands 目录，不移动正在使用的 socket 或合并两套数据。已有 CLI 配对可继续使用，重新配对或撤销会同时清除旧客户端授权。

新版同时提供 `MUSETERM_AGENT_CONTEXT` 与兼容旧 WillDeep 的 `QTERM_AGENT_CONTEXT`。兼容环境变量和旧数据路径仅用于升级，不作为新的产品标识。

1.252.0-rc1 / Build 348 新建终端默认由独立后台持有。正常退出或重开界面不会关闭这些终端；明确关闭标签、分屏或终端才结束相应进程。保存恢复记录失败时取消退出，保留当前查看器。

输出日志有容量上限，截断后的字节回放不能保证完整恢复原 VT 状态。若备用屏幕入口已被淘汰，查看器会在终端解析器确认退出备用屏幕时清除不确定视口，再处理同一批中的 Shell 输出，避免退出 TUI 后残留整屏界面。清理不向 PTY 发送命令，不清空滚动历史；已知备用屏幕的原普通屏幕继续保留。

## 从旧版升级

1.250.0-rc1 等旧版由界面进程直接持有 PTY，没有可用的热迁移协议。不能先退出旧版再声称原终端进程保持。

需要保留当前运行会话时，只更新磁盘上的应用，保留旧 MuseTerm 进程和窗口继续运行。旧窗口仍使用旧版代码，独立后台能力在下一次启动新版后生效。等待当前终端任务结束，再自行关闭旧版并启动新版。安装替换不会清理配置、Profile、快捷命令或历史数据。

## 已使用独立后台后的升级

新版查看器连接兼容的原后台，不为对齐版本而强制重启服务。缺少原进程时显示错误，不静默创建替代 shell 冒充恢复。后台自身崩溃、系统重启及旧 LocalProcess 会话不承诺保留原进程。

MuseTerm 终端后台与 WillDeep Runtime 职责独立。更新 MuseTerm 或 WillDeep CLI 不要求执行 daemon upgrade；要保持正常 Runtime 时，不应调用该命令或重启该进程。原生状态接入需要包含 MuseTerm 协议支持的 WillDeep CLI。
