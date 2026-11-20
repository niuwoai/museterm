# rc26 重启输入审计：已复现写前上下文拒绝

版本：1.251.0-rc26 / Build 341。命令使用现有隔离 QA 宿主，单个真实 PTY 用例配置重复 60 次，无产品源码改动。

结果包：`/private/tmp/qterm-rc26-restart-audit-repeat-01.xcresult`。xcodebuild 退出 65；不能把重复次数参数当作实际完成 60 次。摘要见 [JSON](restart-audit-repeat-unit.json)，Xcode 将重复迭代归并为同一测试标识。

失败断言为 `new process acknowledges input`。捕获到：

- connected=true，metadata=true，订阅本身无错误；
- inputError=`input_context_changed`；
- nextInputSequence=1，写入序号未消耗。

`RuntimeSession.input` 在序号检查后、递增序号和写入前，重新校验 echo 与前台进程组。该错误说明实际写入前至少一个安全上下文与 preflight 不同，不是已写入命令丢失 ACK；目前还不能判断究竟是 echo 还是前台进程组发生变化。

现有用例启动 `/bin/sh -i`，仅等待订阅 connected、运行中和启动回调一次后就发送输入，没有等待 shell 就绪标记。因此要继续区分用例初始化竞态和产品启动命令同类风险；不得仅换成更容易通过的 shell、放宽写前检查、自动重发或延长等待来宣布修复。

rc26 的 621/621 仍为一次完整通过的事实；此次重复失败证明尚存在边界，整体验收不能关闭。测试只使用私有后台及自有 PTY，没有访问正常安装或 Runtime。

## rc27 具体定位与回归

将写前 echo 和前台进程校验的错误码拆开，检查内容和顺序保持。原用例再次重复 60 次，59 通过、1 次失败为 `input_echo_changed`；另一个受控 echo 变化用例 60/60 通过。见 restart-echo-diagnostics-unit.json 及 restart-echo-diagnostics-iterations.json。该次失败说明 shell 初始化改变 echo，后台写前拒绝是正确行为，不应通过重发掩盖。

成功路径保留原交互 `/bin/sh -i`、原订阅/身份/启动次数断言，额外设置私有 PS1 并等待真实提示符；不引入固定延迟、不换成受控 eval shell。安全拒绝路径增加“序号不消耗、旧输入不执行、显式新输入仅执行一次”的实际 PTY 断言。两项各 60 次、共 120/120 通过，实际迭代节点见 restart-shell-ready-iterations.json。当前完整回归 621/621，见 context-full-unit.json。

该结果解释并纠正了已观察到的用例就绪假设，不能扩张为“任何时刻的输入都会成功”：预检后实际上下文变化仍会拒绝，用户需检查终端后明确重新输入。产品启动命令另有既有延迟发送路径；恢复原会话不调用新建回调，真实 SSH Profile 的启动命令覆盖见 authenticated-profile.md，不据此承诺任意 CLI 的语义就绪。
