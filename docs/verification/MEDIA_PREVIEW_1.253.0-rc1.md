# 图片与 Markdown 预览验收

版本：1.253.0-rc1 / Build 351；日期：2026-10-26。

## 自动化

- 最终完整单测 661/661 通过，结果包 `/private/tmp/qterm-preview-all-unit-final.xcresult`；中文标准输入及 MCP 工具目录专项 11/11 通过，结果包 `/private/tmp/qterm-preview-cli-final.xcresult`。

- 预览、原生图片、鼠标输入、历史重放：31/31 通过，结果包 `/private/tmp/qterm-preview-core-final-b.xcresult`。
- 修正显式拆出窗口后的焦点后，预览专项 7/7 再次通过，结果包 `/private/tmp/qterm-preview-window-final.xcresult`。
- 覆盖 GFM 标题/表格/代码/任务列表、原始 HTML 和危险链接、相对图片和符号链接越界、文件大小及格式错误、原子替换刷新和删除、真实生成 CLI 文件入口、MCP 文本入口、授权拒绝、后台来源绑定、过期请求拒绝。
- Kitty、iTerm2、Sixel 序列经过 QTerm 原生视图的历史输出通路后均保留图片，终端调整尺寸后仍有图片，后续文字正常输出；既有鼠标、滚动和退出残留回归通过。
- XCTest UI Runner 两次在启用自动化模式时超时，未执行产品断言；不将它计作界面验收通过。新增 UI 测试保留供正常自动化环境运行。

## 隔离应用实测

在独立 bundle ID、工具根目录、后台和内存凭据的 QTerm QA 中完成，未接管正式终端。

- 文件选择器打开 Markdown，实际显示标题、段落、代码块和列表；源码开关能显示原文。
- 实际 CLI `preview --tab UUID FILE` 经工具桥在来源终端右侧显示文件。
- 独立窗口立即激活，点击「收回侧栏」后恢复同一份预览；初次发现的不激活问题已修正并复验。
- PNG 实际显示，放大、适应窗口及拖动宽度正常，终端区域同步保留。
- 预览展开时终端执行 `printf`，状态快照确认预期输出；QA shell PID 34135、generation 保持不变。
- Markdown 文件内容修改后，GUI 标题从 `Live refresh original` 自动变为 `Live refresh updated`。
- 本机 HTTP 图片夹具初始请求数为 0；点击「加载网络图片」后为 1，GUI 从占位文字变为图像；文件刷新后重新显示占位，不自动再次请求。
- 实际独立 MCP 进程向后台终端发送 Markdown，当前标签 UUID 保持不变且当前终端无预览；切回来源终端才出现 `MCP background acceptance` 内容。
- QA 查看器、专用后台和 HTTP 夹具均已退出；正常 WillDeep Runtime 未重启。

## 使用边界

图片使用首帧和最长边 4096 像素的预览；Markdown 2 MiB、图片 20 MiB。预览是临时界面状态，不随终端恢复自动重新读取文件。SSH 来源支持正文请求，不把远端路径当成本机路径。CLI/MCP 成功只表示请求接受，具体加载结果由界面显示。
