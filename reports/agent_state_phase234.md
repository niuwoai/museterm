# Agent 待处理、事件等待与可靠性验证

版本：`1.250.0-rc1`，Build `314`。仅本地开发，未提交、未发布、未替换已安装应用。

| 测试结果包 | 结果 | 通过 | 失败 | 跳过 |
|---|---|---:|---:|---:|
| qterm-agent-phase234-verified.xcresult | Passed | 482 | 0 | 0 |
| qterm-agent-phase234-layout.xcresult | Failed | 1 | 2 | 0 |
| qterm-agent-phase234-layout-retry.xcresult | Failed | 2 | 1 | 0 |
| qterm-agent-phase234-badge-screen.xcresult | Passed | 1 | 0 | 0 |
| qterm-agent-phase234-ui-unlocked.xcresult | Failed | 2 | 1 | 0 |
| qterm-agent-phase234-detached-axwait.xcresult | Passed | 1 | 0 | 0 |

结果包按时间排列；同一测试以最后一次结果为准，不叠加重复用例。

最新去重结果：482/482 通过，0 失败，0 跳过。

## 边界

- 界面测试使用显式状态夹具；未运行真实 Claude/Codex 付费任务。
- 未自动安装原生生命周期钩子；包装进程和 SSH 远端需显式结构化接入。
- 系统通知定位校验有自动化测试；未向用户申请新的系统通知权限或发送测试通知。
- 跨应用退出保活、原生 Agent 钩子安装和完整终端正文增量流不在本次范围。

## 首轮失败记录

专项测试发现 Ruby 等待清理标记作用域问题，已修复取消和 EOF 清理；界面测试按实际按钮合并可访问性文本验证已读状态。文件桥验收移至使用独立目录的原生测试宿主，避免 UI runner 与 App 容器目录隔离。布局复验曾出现截图超时和控件未找到，该轮截图可见系统钥匙串解锁弹窗；未操作弹窗。用户处理弹窗后，徽标和待处理列表通过，窗口计数等待仍超时，但失败截图确认两个窗口已显示；测试改用 XCTest 直接等待第二个窗口，保留事项点击和悬浮定位断言。失败记录保留在对应临时 xcresult 中。
