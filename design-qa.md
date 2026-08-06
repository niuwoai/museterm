# AI 辅助右下角操作按钮 Design QA（1.239.0-rc11）

- source visual truth path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc10-bottom-context.png`
- implementation screenshot path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/com.openai.sky.CUAService/QTerm Screenshot 2026-08-06 at 10.32.39 AM.jpeg`
- focused implementation path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc11-bottom-actions.png`
- combined comparison path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc11-layout-comparison.png`
- viewport: QTerm 主窗口 1167 × 768 px；源与实现聚焦裁切均为 942 × 143 px；另复验约 902 × 768 px 窄窗口
- CSS size / density normalization: 原生 macOS App，无 CSS viewport；源与实现裁切保持相同 942 px 原始宽度，未拉伸纵横比
- state: 浅色皮肤；本地 zsh；AI 辅助输入 7 行并停留在最多 5 行的滚动状态

## Full-view comparison evidence

- 字体与排版：正文、上下文与按钮图标继续使用原有系统字体和 SF Symbols；上下文与操作按钮在同一基线上。
- 间距与布局节奏：生成与关闭按钮从右上移到右下，和左侧终端上下文组成完整底部行；按钮间与上下文间使用固定 10 pt 间距。
- 颜色与视觉令牌：材质背景、强调色、次要文字色、描边和阴影全部复用 QTerm 现有皮肤。
- 图像与资产质量：没有新增位图或替代资产；生成和关闭继续使用原有 SF Symbols，清晰度与状态样式保持一致。
- 文案与内容：上下文仍完整包含本地/远程标识、用户与主机、当前目录和 shell；没有新增硬编码可见文案。
- 响应行为：正常与窄窗口下按钮保持完整，空间不足时仅中间截断上下文；正文继续获得整行输入宽度。

## Focused region comparison evidence

组合图上方为 rc10 的右上角按钮布局，下方为 rc11 的右下角按钮布局。两张图均为 942 × 143 px，可直接确认按钮已落到底部信息行右端；正文宽度和输入条整体高度没有变化。

## Findings

- 最终复验没有可执行的 P0、P1 或 P2 视觉问题。
- P3：窄窗口下超长主机或目录会从中间省略，以保证两个操作按钮永远完整；悬停上下文仍可查看完整内容。

## Primary interactions tested

- 打开 AI 助手，确认空输入时生成按钮禁用，两个按钮位于右下角。
- 写入 7 行中文文本，确认最多展示 5 行、内部滚动保持有效，按钮仍位于底部信息行。
- 将窗口缩窄到约 902 px，确认上下文、生成和关闭按钮均未溢出或换行。
- 未按 Enter、未点击生成按钮，避免触发外部 AI 请求。

## Comparison history

1. rc10 将上下文移到底部，但生成与关闭按钮仍在右上，视觉重心分散。
2. rc11 将两个按钮并入底部信息行右端，同时让上下文承担可截断区域。
3. 同尺寸组合对照和窄窗口复验均未发现新的 P0、P1 或 P2 问题。

## Implementation checklist

- [x] 生成与关闭按钮位于右下角
- [x] 上下文位于同一底部行左侧
- [x] 按钮优先完整、上下文可中间截断
- [x] 正文继续获得完整可用宽度
- [x] 五行上限与超限滚动保持有效
- [x] 相关单元测试与真实 App 验收通过

final result: passed

---

# AI 辅助底部上下文行 Design QA（1.239.0-rc10）

- source visual truth path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc9-five-line-context.png`
- implementation screenshot path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/com.openai.sky.CUAService/QTerm Screenshot 2026-08-06 at 10.26.28 AM.jpeg`
- focused implementation path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc10-bottom-context.png`
- combined comparison path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc10-layout-comparison.png`
- viewport: QTerm 主窗口 1167 × 768 px；源与实现聚焦裁切均为 942 × 143 px；另复验约 902 × 768 px 窄窗口
- CSS size / density normalization: 原生 macOS App，无 CSS viewport；源与实现裁切保持相同 942 px 原始宽度，未拉伸纵横比
- state: 浅色皮肤；本地 zsh；AI 辅助输入 7 行并停留在最多 5 行的滚动状态

## Full-view comparison evidence

- 字体与排版：输入正文与上下文继续使用原有系统字体和字号；上下文改为正文下方的 caption 独立行，层级更清楚。
- 间距与布局节奏：正文与上下文仅保留 4 pt 间距；主机、目录信息不再占用正文横向空间，生成和关闭按钮固定在右上。
- 颜色与视觉令牌：材质、描边、阴影、强调色和次要文字色完全复用 QTerm 现有皮肤，没有新增视觉令牌。
- 图像与资产质量：继续使用原有 SF Symbols；没有新增位图、替代图标或低清资产。
- 文案与内容：终端上下文内容没有删减，仍包含本地/远程标识、用户与主机、当前目录和 shell；没有新增硬编码界面文案。
- 响应行为：正常与窄窗口下正文均使用按钮之外的完整可用宽度；超过 5 行后内部滚动，上下文始终位于最下面一行。

## Focused region comparison evidence

组合图上方为 rc9 的右侧上下文布局，下方为 rc10 的底部上下文布局。两张图均为 942 × 143 px，可直接看出正文区域从约半宽扩展到接近整行；上下文移至底部后没有额外扩大五行状态的整体高度，按钮仍完整可用。

## Findings

- 最终复验没有可执行的 P0、P1 或 P2 视觉问题。
- P3：单行空输入状态比旧版多一行上下文高度，但换取了正文完整宽度和稳定的信息层级；实际增加高度较小，属于可接受取舍。

## Primary interactions tested

- 打开 AI 助手，确认空输入状态下上下文位于正文下方，生成按钮保持禁用。
- 写入 7 行中文文本，确认最多展示 5 行且后续内容由内部滚动承接。
- 将窗口缩窄到约 902 px，确认正文、底部上下文、生成和关闭按钮均未被裁切。
- 未按 Enter、未点击生成按钮，避免触发外部 AI 请求。

## Comparison history

1. rc9 将上下文固定在正文右侧，虽然避免信息消失，但明显压缩了长文本的输入宽度。
2. rc10 将上下文移到底部独立行，正文恢复完整横向空间，按钮改为顶对齐。
3. 同尺寸组合对照和窄窗口复验均未发现新的 P0、P1 或 P2 问题。

## Implementation checklist

- [x] 上下文位于输入区最下面一行
- [x] 正文获得完整可用宽度
- [x] 生成与关闭按钮固定在右上
- [x] 1～5 行自适应与超限滚动保持有效
- [x] 正常与窄窗口均无裁切
- [x] 相关单元测试与真实 App 验收通过

final result: passed

---

# AI 辅助终端上下文常驻 Design QA（1.239.0-rc9）

- source visual truth path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-6da6cb31-80d6-4ac3-bb18-320385b3334e.png`
- implementation screenshot path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/com.openai.sky.CUAService/QTerm Screenshot 2026-08-06 at 10.18.34 AM.jpeg`
- focused implementation path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc9-five-line-context.png`
- combined comparison path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/rc9-reference-comparison.png`
- viewport: QTerm 主窗口 1167 × 768 px；源截图 942 × 64 px；实现聚焦裁切 942 × 143 px；组合图 942 × 207 px
- CSS size / density normalization: 原生 macOS App，无 CSS viewport；源截图与实现裁切均保持 942 px 原始宽度，未拉伸纵横比
- state: 浅色皮肤；本地 zsh；AI 辅助输入框聚焦；实现输入 7 行并停留在最多 5 行的滚动状态

## Full-view comparison evidence

- 字体与排版：上下文继续使用原有系统 caption 字体，输入区继续使用现有正文样式；没有新增字体、字重或硬编码界面文案。
- 间距与布局节奏：上下文区域获得 190～380 pt 的稳定宽度与更高布局优先级，长输入不会再将它挤出提示条；生成与关闭按钮位置保持稳定。
- 颜色与视觉令牌：材质背景、浅色描边、强调色与次要文字色均复用现有 QTerm 皮肤，没有引入新颜色。
- 内容完整性：正常窗口宽度下完整显示“本地 · 用户@主机 · 当前目录 · shell”；极窄宽度下从中间截断，并通过 Help 提供完整文本。
- 响应行为：单行状态保持原有紧凑高度；输入超过 5 行后仅输入区内部滚动，上下文仍常驻右侧。

## Focused region comparison evidence

组合图上方是用户提供的原版单行状态，下方是修复后的 7 行输入状态。两者统一为 942 px 宽，可直接核对上下文所在位置：修复后输入条增高至 5 行上限时，本地标识、用户与主机、当前目录和 shell 仍完整可见，生成与关闭控件也未偏移或裁切。

## Findings

- 最终复验没有可执行的 P0、P1 或 P2 视觉问题。
- P3：极窄窗口下无法物理容纳全部上下文，因此采用中间省略并保留悬停完整文本；正常窗口宽度下不发生省略。

## Primary interactions tested

- 通过“标签 → AI 助手”打开输入条，确认单行状态下完整上下文可见。
- 直接写入 7 行中文文本，确认输入条停在 5 行高度并由内部滚动承接后续内容。
- 在 5 行状态检查辅助功能树与截图，确认上下文文本仍存在且完整显示。
- 未按 Enter、未点击生成按钮，避免触发外部 AI 请求。

## Comparison history

1. 原版截图显示上下文在输入条右侧持续可见。
2. 新版长文本布局曾因输入框优先级较高，把上下文压缩到不可见，属于布局回归而非功能移除。
3. 修复后为上下文保留稳定宽度并提高布局优先级；单行与 5 行状态复验均通过。

## Implementation checklist

- [x] 本地/远程标识常驻
- [x] 用户与主机常驻
- [x] 当前目录与 shell 常驻
- [x] 长输入最多 5 行并内部滚动
- [x] 极窄状态中间省略并保留完整 Help
- [x] 相关单元测试与真实 App 视觉验收通过

final result: passed

---

# AI 辅助输入条自适应 Design QA（1.239.0-rc7）

- source visual truth path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-b67af152-3d2a-4f43-ad4a-496fe61d0c5f.png`
- implementation screenshot path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/com.openai.sky.CUAService/QTerm Screenshot 2026-08-06 at 10.02.05 AM.jpeg`
- focused implementation path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/ai-assistant-five-line-implementation.png`
- combined comparison path: `/Users/rocky/.codex/visualizations/2026/08/06/019fd4c9-d011-71c3-b072-99bd2c012da3/museterm-ai-assistant/ai-assistant-reference-comparison.png`
- viewport: QTerm 主窗口 1167 × 768 px；源截图 933 × 75 px；实现聚焦裁切归一化为 933 × 126 px；组合图 933 × 201 px
- CSS size / density normalization: 原生 macOS App，无 CSS viewport；源截图与实现裁切均按 1× 像素宽度归一化到 933 px，未拉伸纵横比
- state: 浅色皮肤；本地 zsh；AI 辅助输入框聚焦；实现输入超出 5 行并停留在文本末尾

## Full-view comparison evidence

- 字体与排版：实现继续使用原有系统字体、字号与行高；长文本自然折行，当前可见 5 行，未出现截断、省略号或单行横向挤压。
- 间距与布局节奏：输入条保留原来的水平内边距、圆角、描边与阴影；高度只随正文增加，右侧上下文、生成和关闭控件保持稳定，没有被正文推离可视区域。
- 颜色与视觉令牌：材质背景、强调色、主次文字色和边框均沿用现有 QTerm 皮肤，和源截图一致。
- 图像与资产质量：该组件没有位图资产；闪光、生成、关闭继续使用原有 SF Symbols，没有新增替代图形或低清资源。
- 文案与内容：占位文案与上下文文案继续走现有 i18n；本次没有新增硬编码界面文案。
- 响应行为：1～5 行由多行 TextField 驱动输入条自适应增高；超过 5 行后高度保持不变，焦点跟随插入点在输入区内纵向滚动。

## Focused region comparison evidence

组合图上方保留用户提供的原始单行状态，下方为同一输入条的超长内容状态。两者统一为 933 px 宽，可直接核对闪光图标、材质、边框、上下文、生成按钮与关闭按钮；实现只扩展正文高度，没有改变现有视觉语言。由于本次目标就是单行与五行上限的状态变化，聚焦输入条比整窗对比更能排除终端内容和侧栏差异。

## Findings

- 最终复验没有可执行的 P0、P1 或 P2 视觉问题。
- P3：macOS 默认使用覆盖式滚动条，静止时不会常驻显示轨道；超出 5 行后输入区仍可滚动并自动跟随插入点，符合平台行为。

## Primary interactions tested

- 通过“标签 → AI 助手”打开输入条，确认输入框自动聚焦。
- 写入远超 5 行的中文长文本，确认输入条止于 5 行高度，右侧按钮仍完整可用。
- 确认焦点停留在文本末尾且可见内容移动到末尾，验证超过上限后由输入区内部滚动承接。
- 未点击生成按钮，避免触发外部 AI 请求；原生 App 没有浏览器控制台，编译日志未出现本功能新增错误。

## Comparison history

1. 源状态显示固定单行输入条，长文本会横向挤压；需求明确要求自然换行、最多 5 行、继续输入时滚动。
2. 修复后真实 App 截图显示 5 行长文本，输入条高度受控，图标、上下文和按钮均保持原位。
3. 组合对照未发现新的 P0、P1 或 P2 问题。

## Implementation checklist

- [x] 长文本自然换行
- [x] 输入条按 1～5 行自适应高度
- [x] 超过 5 行后内部纵向滚动
- [x] 生成与关闭按钮不被正文挤出
- [x] 复用现有皮肤、i18n 与 SF Symbols
- [x] 相关单元测试与主 App 编译通过

final result: passed

---

# AI 命令助手 Design QA

- source visual truth path: `/Users/rocky/.codex/generated_images/019f64ee-48f7-7ec1-a3f7-e33e952e9e76/exec-77ed86fd-23a0-42e5-b039-1444798994b3.png`
- implementation screenshot path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/com.openai.sky.CUAService/QTerm Screenshot 2026-07-15 at 7.58.57 PM.jpeg`
- combined comparison path: `/Users/rocky/.codex/visualizations/2026/07/15/019f64ee-48f7-7ec1-a3f7-e33e952e9e76/ai-command-design-qa-comparison-pass3.png`
- viewport: QTerm 主窗口 1160 × 768；参考图为 1488 × 1056 的六阶段交互板
- state: 浅色主题；本地 zsh；AI 已返回两个只读候选；右上浮层打开；终端画布尺寸未改变

## Full-view comparison evidence

- 信息架构：实现保持参考图的“终端原位工作”流程：底部自然语言输入条切换为终端右上浮层，浮层内依次显示完整上下文、不会自动执行的信任提示、候选命令、解释、风险标签和操作按钮。
- 字体与排版：界面沿用 QTerm 的系统字体；上下文和命令使用等宽字体，标题、正文、辅助说明与风险标签层级清楚。候选命令最多三行、解释最多五行，避免长内容挤坏浮层。
- 间距与布局节奏：最终浮层固定在终端画布右上，宽 470 pt、上边距 24 pt、右边距 22 pt；内容按实际高度收缩，不再出现大块无意义空白，也不会把终端挤成分栏。
- 颜色与视觉令牌：实现复用当前 QTerm 皮肤的材质、发丝线、阴影和强调色；风险使用语义色，浅色背景下文字、边框和按钮对比清楚。
- 图像与资产质量：该流程没有品牌位图或插画；实现统一使用 SF Symbols，图标清晰、风格一致，没有手绘 SVG、字符图标或占位图。
- 文案与内容：输入提示、关闭后果、上下文、风险和“填入当前终端”均为独立可理解的产品文案，全部走中英文 i18n。当前是本地环境，因此没有伪造参考图里的 `PROD` 标签。
- 状态与行为：浮层 z-index 高于终端与右侧工具面板；点击 `×` 或按 `Esc` 会取消生成并结束本轮；填入只发送命令字节，不发送 Return。
- 可访问性：输入框、关闭、候选、复制、重新提问和填入按钮均出现在 macOS 辅助功能树中，并提供可读名称或 Help；键盘关闭路径有效。

## Focused region comparison evidence

组合图保留了参考六阶段交互板的原始 1488 px 宽度，并把最终原生截图等宽放在下方；阶段 3、阶段 4 与实现浮层中的上下文、候选、解释、风险、关闭和填入控件均可直接读清。核心细节无需再次放大裁切。

## Findings

- 最终复验没有可执行的 P0、P1 或 P2 视觉问题。
- P3：参考图以生产 SSH 场景演示，实现截图使用本地 zsh，因此生产标记与“生产环境填入”提示没有在同一张截图里出现；这属于运行上下文差异，生产提示逻辑由模型状态和单元测试覆盖。

## Primary interactions tested

- 通过“标签 → AI 助手”打开入口，确认底部自然语言输入条自动聚焦并显示本地用户、主机、目录与 shell。
- 输入“显示当前目录下占用空间最大的 10 个文件或目录”，AI 返回两个单行候选；应用在本地重新评估风险并标为“只读 · 低风险”。
- 点击“填入当前终端”后，命令原地出现在 shell 提示符后，未自动执行，界面提示“已填入 · 按 Return 执行”。
- 点击 `×` 后浮层关闭，辅助功能树出现“本轮 AI 辅助已结束”，原终端内容不被清空或重排。
- 独立双击 Control 无法由当前 Computer Use 驱动合成；修饰键检测、打断序列、禁用状态和设置持久化由聚焦单元测试覆盖。
- 原生应用没有浏览器控制台；构建日志未出现本功能新增的编译错误。

## Comparison history

1. 第一次对照发现 P2：浮层视图使用内容固有尺寸，虽然 z-index 正确，但被父级 ZStack 放在终端中间，不够靠右。
2. 修复：让 AI 覆盖层占满终端画布，并以 `.topTrailing` 对齐；复验截图显示浮层固定到右上。
3. 第二次对照发现 P2：Review 阶段的 ScrollView 自动扩张到 430 pt，短内容下产生大面积空白，遮挡终端过多。
4. 修复：让浮层按内容高度收缩，并限制候选与解释的最大行数；第三次对照显示一到两个候选都保持紧凑。
5. 第三次组合对照未发现新的 P0、P1 或 P2 问题。

## Implementation checklist

- [x] 双击可配置修饰键唤起底部自然语言输入
- [x] 生成与结果阶段使用终端右上高层级浮层
- [x] 浮层可关闭，关闭立即结束本轮 AI 辅助
- [x] 上下文、解释、本地风险重判和候选命令完整展示
- [x] 填入但不执行，生产上下文使用更强提示
- [x] 中英文 i18n 与辅助功能标签

final result: passed

---

# 会话隧道 Design QA

- source visual truth path: `/Users/rocky/.codex/generated_images/019f7a9a-2a32-7923-af50-7d3a6e7d9524/exec-dba4eadc-8a1f-49b1-94f4-44b59a1c3457.png`
- implementation screenshot path: `/Users/rocky/.codex/visualizations/2026/07/19/019f7a9a-2a32-7923-af50-7d3a6e7d9524/session-tunnel-implementation.png`
- combined comparison path: `/Users/rocky/.codex/visualizations/2026/07/19/019f7a9a-2a32-7923-af50-7d3a6e7d9524/session-tunnel-comparison.png`
- viewport: 2880 × 1800 Retina 桌面截图；QTerm 主窗口约 2445 × 1570 px
- state: Midnight 深色皮肤；会话隧道运行中；终端蒙版、右侧检查器和停止操作同时可见

## Full-view comparison evidence

- 信息架构：实现保留参考图的三栏结构，在现有 QTerm 左侧工作区与中央终端之外新增右侧会话隧道检查器；运行状态、服务名称、三段路由、指标、连接列表、关闭警告和停止操作顺序一致。
- 字体与排版：复用应用系统字体与等宽端点文本；状态、服务名、路由标题、端点和次要指标形成稳定层级，英文长主机名保持单行并正确截断。
- 间距与布局节奏：检查器宽度与现有右侧工具面板一致；顶部标题、14 pt 内容内边距、18 pt 分组间距和固定底部操作区在大窗口下仍保持紧凑。
- 颜色与视觉令牌：实现遵循用户选择的 Midnight 皮肤，绿色表达运行状态，橙色表达关闭标签风险，停止按钮使用现有检查器的边框按钮样式与 destructive 语义；发丝线、卡片背景和强调色来自现有设计系统。
- 图像与资产质量：界面仅使用 SF Symbols，没有占位图、手绘 SVG 或字符图标；路由与服务图标在 Retina 截图中清晰。
- 文案与内容：蒙版明确说明终端输入已暂停并会在停止后恢复；检查器清楚区分本机入口、当前会话和远端服务。全部对外文本均走中英文 i18n。
- 状态与行为：运行时蒙版覆盖终端交互区域但保留足够上下文感知；右侧检查器保持可操作。停止后自动移除蒙版并恢复原终端，不改变标签或工作区布局。
- 可访问性：创建、目标主机、本机端口、开始、运行态、蒙版、检查器和停止按钮均有稳定 accessibility identifier；UI 自动化覆盖完整主路径。

## Focused region comparison evidence

纵向组合图把参考图放在上方、实现截图裁切放在下方并统一为 1400 px 宽。可以直接对照中央蒙版与右侧检查器：核心结构、状态颜色、端点层级、固定底部警告和停止按钮均与设计意图一致；实现按现有 QTerm 深色设计系统落地，没有机械复制参考图的浅色表面。

## Findings

- 最终复验没有可执行的 P0、P1 或 P2 视觉问题。
- P3：参考图用竖向连线强化三段路由，实现采用系统图标加分隔线，视觉更贴合 QTerm 现有检查器；信息完整性不受影响。
- P3：参考图将停止按钮直接渲染为红色，实现沿用 QTerm 检查器的主题强调色，但保留 destructive 角色与独立橙色关闭警告；不影响操作辨识与可访问性。
- P3：自动化截图包含桌面背景和其他窗口边缘；QTerm 窗口本身无遮挡，裁切后的组合对照已隔离核心实现区域。

## Primary interactions tested

- 打开会话隧道创建面板，确认名称、目标主机、目标端口和本机端口输入可见。
- 启动隧道后，确认终端蒙版与右侧检查器出现，状态进入 `running`。
- 运行态截图确认三段路由、运行时间、传输量、连接数、关闭标签警告和停止按钮均可见。
- 点击停止隧道，确认蒙版在超时窗口内消失，终端恢复可用。
- 真实交互式 PTY 单测覆盖短 loader、raw mode 助手载入与停止；端到端 TCP 回环覆盖本地监听到远端服务的字节双向转发。

## Comparison history

1. 运行态首轮已经匹配参考图的信息架构：中央蒙版、右侧检查器、固定底部风险说明与停止操作均完整。
2. 组合对照确认蒙版、右侧检查器与现有工作区设计系统协调，未发现新的 P0、P1 或 P2 问题。

## Implementation checklist

- [x] 二跳、三跳后的当前交互式终端可启动临时 TCP 隧道
- [x] 本机监听仅绑定 `127.0.0.1`
- [x] 远端助手不落盘，使用带随机 token 的 JSONL + Base64 复用协议
- [x] 终端运行态蒙版与输入阻断
- [x] 右侧检查器、指标、连接列表与停止操作
- [x] 中英文 i18n、可访问性与自动化覆盖

final result: passed
