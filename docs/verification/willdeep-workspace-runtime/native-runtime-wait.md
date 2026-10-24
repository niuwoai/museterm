# WillDeep 原生状态 CLI 验证

额外验证了后台等待：原审批后按准确 instance/run 注册 idle 等待，全部客户端脱离至少 31 秒期间仍不提前命中；实际回答审批后，等待结果为 matched，Agent 的 lastResult 为 completed，并且 sessionID/taskID 与原审批一致。权威结果见同名 JSON 的 backendWaitResult；该项不是通用 CLI/MCP 自动路由或完整 GUI 验收。

通过：true
失败：无

实际 WillDeep CLI/Runtime + 独立 QTerm 后台真实 PTY/状态桥/待处理；本机 mock 模型；尚非 QTerm 图形界面联调

本机模型请求：2，原生状态报告：6，注入一次丢失确认：false。
