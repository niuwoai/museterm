# 侧栏分区展开状态验证

版本：`1.262.0-rc1` / Build `386`。

本次整合包含已合入主分支的 SSH 退出恢复与 16 张图标的无损压缩。原生测试使用独立 QA 应用标识和构建目录，不替换已安装 MuseTerm。

- `focused.json` / `focused.md`：侧栏偏好与真实 SwiftUI 宿主专项结果。
- `unit.json` / `unit.md`：最终整合版本的完整原生单元与集成回归结果。
- `native-gui/app-smoke.json` / `native-gui/app-smoke.md`：实际 QA App 启动、创建标签、Runtime 控制租约内发送命令、读取屏幕结果、释放控制和关闭测试标签。

侧栏视图回归覆盖已保存的反默认值在首屏恢复、可空 workspace 偏好尚未注入、两个持续存活宿主同步更新、普通无身份折叠区的本地状态、隐藏与重新显示、重排及新宿主恢复。它承载真实 `SidebarSection` 与可观察分区列表，不把仅模型读写当作视图验证。实际 App 冒烟的范围为标签与终端交互；未将该冒烟声称为逐项侧栏点击或两窗口操作验收。

专项可从仓库根目录执行：

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ruby scripts/sidebar_section_test_report.rb musetermTests/SidebarSectionExpansionTests musetermTests/AppPolicyTests
```

完整原生回归：

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ruby scripts/sidebar_section_test_report.rb
```

构建完成后的实际应用交互：

```bash
MUSETERM_QA_REPORT_DIRECTORY="$PWD/reports/sidebar-section-expansion/native-gui" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ruby scripts/ssh_terminal_cleanup_app_smoke.rb
```

如已有解析完成的 Swift Package 缓存，可以通过 `MUSETERM_TEST_SOURCE_PACKAGES` 指定缓存根目录。JSON 和 Markdown 报告保留版本、范围、计数和结果；完整构建日志与 `.xcresult` 留在忽略的 `.derivedData/ssh-terminal-cleanup`。终端原始截图可能包含本机用户和主机标识，仅保留本地并由本目录 `.gitignore` 排除。本次窗口截图抓取未成功（`could not create image from window`），没有图像验收证据；实际 App 交互结果和真实 SwiftUI 视图测试结果分别保留。
