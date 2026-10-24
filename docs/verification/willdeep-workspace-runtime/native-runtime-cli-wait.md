# WillDeep 原生状态 CLI 验证

通过：true
失败：无

实际 WillDeep CLI/Runtime + 独立 QTerm 后台真实 PTY/状态桥/待处理；本机 mock 模型；尚非 QTerm 图形界面联调

本机模型请求：2，原生状态报告：6，注入一次丢失确认：false。

额外路径：按当前 MuseTermCLIInstaller.script 属性与相同 Swift 字符串模块生成私有 QTerm CLI。自有元数据模拟 UI 不在线，CLI 自动路由到后台；原生文件等待与 CLI 两个等待均在全查看客户端脱离 31 秒时未提前完成，审批后都匹配同 task 的 completed。CLI 时间为字符串；源脚本和 helper SHA 记录在 JSON。不是实际 GUI 退出操作复验。
