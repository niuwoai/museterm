# 静默后首包与真实终端窗口专项

当前 embedded helper 与真实 SwiftTerm 窗口专项；含超过请求写超时的静默后首包、同 PID 重连、设备回复、控制、真实工具桥；不是正常 App 退出恢复

- 通过：7；失败：0；跳过：0
- 原始结果：`/private/tmp/qterm-runtime-idle-view-01.xcresult`
- 测试中的 /bin/sh 静默 6 秒后输出，验证首包不会按此前静默时长被误判写超时。
- 全目标仍未完成，正常产品默认后台和退出重开恢复尚待实现与验收。
