# MuseTerm 性能报告

> 接入版本 v1.264.0-rc1（Build 390）

「共享性能报告」默认开启，可在「设置 › 行为」随时关闭。已保存的关闭选择在重启后继续生效。关闭共享后停止采样、取消正在进行的抓栈，并停止发起新请求。已发出的请求会在超时限制内结束。确认「删除已共享的报告」会关闭共享，等待进行中的上传结束，再请求 some.im 删除该安装已发送的报告。安装标识保留在本机，便于出现超时或服务端迟到写入时再次请求删除。

## 采样与上报

- AppDelegate 管理一个后台采样任务。开启后先等待 20 秒，再以约 1 秒间隔读取 MuseTerm 界面进程的累计 CPU 时间。单核满载为 100%。CPU 严格超过 30% 且持续至少 3 秒时触发。缺失样本或间隔超过 2.5 秒会打断持续区间。同一次启用中，两次抓栈间隔至少 10 分钟，滚动 24 小时最多尝试抓栈 30 次。
- 触发时记录 `museterm.foreground` 或 `museterm.background`，并用 macOS `/usr/bin/sample` 抓取该进程的 2 秒全线程调用栈。独立的 `museterm-runtime`、本地 shell 和 SSH 子进程不在采样范围。采样可能错过很快消退的峰值。
- 调用树保留线程结构和地址。MuseTerm 与系统映像保留符号、地址和 UUID，供符号化使用。采样头、路径、进程名、线程和队列的自定义标签、第三方映像名和源文件位置在本机移除。可解析的内存占用数字也会保留。原始样本写入无文件路径的私有临时描述符，抓栈结束后关闭。待发报告不跨应用重启保存。发送失败后丢弃该报告。
- 请求包含随机安装和报告 UUID、应用版本及构建号、系统版本、架构、界面语言、抓栈触发时间、前后台状态、CPU 指标和脱敏调用栈。不上报终端输入、输出、命令、SSH 主机、环境变量或账户凭据。

## some.im 接收与查询

| 项目 | 值 |
| --- | --- |
| 上报接口 | `POST https://og.niuwoai.com/api/v1/public/telemetry/perf-reports` |
| 应用标识 | `museterm` |
| 界面标识 | `museterm.foreground`、`museterm.background` |
| 调用栈格式 | `macos-sample-v1` |
| 删除接口 | `POST https://og.niuwoai.com/api/v1/public/telemetry/forget` |

在 [some.im 客户端性能报告](https://some.im/admin/perf-reports) 中将客户端设为「全部」，按 UTC 日期查询，客户端列显示 `museterm`。后台列表 API 支持 `app_id=museterm` 精确筛选。服务端报告默认保留 30 天，受部署配置影响。
