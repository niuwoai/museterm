# 图片与 Markdown 预览

版本：1.253.0-rc1 / Build 351。

通过工具栏的文档按钮选择文件，⌘ 单击本机图片/Markdown 路径，或在终端选中文本后右键「预览选中内容为 Markdown」。预览在来源终端右侧按需显示；切换终端显示相应预览，不替换 PTY 内容。拖动分隔线调整宽度，可独立窗口查看、收回侧栏或关闭。

Markdown 支持标题、表格、代码块、引用、列表、任务列表、链接和图片，可切换源码、复制正文；本地文件每秒检查变更并重新加载（包含原子替换）。图片可适应窗口、缩放、复制，动图显示首帧，大图预览缩略至最长边 4096 像素。

## Agent 入口

启用并配对 QTerm 工具写入权限，先用 `qterm tabs --json` 查询来源终端的完整 UUID：

```sh
qterm preview --tab UUID /absolute/path/report.md
qterm preview --tab UUID /absolute/path/screenshot.png
qterm preview --tab UUID --stdin < report.md
qterm preview --tab UUID --close
```

MCP 工具 `preview` 接受 `tab` 和 `path`、`markdown`、`close:true` 三选一。来源 UUID 必填，UI 在线且请求未过期才接受；成功响应表示已接收，实际加载状态和错误在预览区展示。对后台标签的请求不会切换当前标签，也不获取输入控制租约。SSH 标签只接受 Markdown 正文，不把远程文件路径误作本机路径。

## 资源边界

- Markdown 上限 2 MiB，图片上限 20 MiB，只读取普通文件。
- Swift Markdown 解析 GFM；仅允许 AST 生成的 HTML，原始 HTML 作为文本显示，WebKit 脚本与持久网站数据关闭。
- Markdown 中相对图片仅限文档所在目录内，解析真实路径后禁止越界；图片以受限缩略图内嵌，WebKit 无本机目录访问授权。
- 网络图片默认不请求，用户点击后逐张有界下载，超时和错误显示提示；HTML 内容安全策略禁止网络资源，链接仅由用户点击后交给系统浏览器。
- 预览是界面临时状态，关闭终端即释放预览；恢复终端不会自动打开文件或发起网络请求。
