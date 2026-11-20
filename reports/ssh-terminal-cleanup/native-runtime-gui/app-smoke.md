# 原生应用隔离交互验证

- 版本：1.261.0-rc3
- 结果：PASS
- 范围：实际 QA App；AppleScript 创建标签与读取屏幕，Runtime 租约内输入。
- SSH 异常退出恢复另由专项原生回归覆盖；用例和结果见 focused.json / focused.md。
- 旧 AppleScript 输入冒烟的失败记录保留于相邻 native-gui 目录。
- 截图仅保留本地并由 Git 忽略，上传前必须脱敏终端中的用户及主机标识。
- 复用建议：可通过 /run-skill-generator 固化隔离启动和租约驱动。

- 实际 QA 应用启动并显示终端标签
- 通过 AppleScript 创建独立测试标签
- 取得仅属于本次 QA 的 AI 控制租约
- 按当前 generation、控制 epoch 与前台进程校验发送终端命令
- 从实际 App 屏幕读到命令执行结果，排除仅命令回显
- 通过 Runtime 正常释放本次控制租约
- 关闭本次创建的测试标签并确认已从实际 App 状态移除
