# Agent 标识资源

侧栏和分屏标题优先显示工具品牌标识，工具名、状态、来源和可信度仍保留在悬停提示及无障碍标签中。当前终端 Agent 均使用 CLI 展示；终端框和提示箭头是 MuseTerm 的界面装饰，品牌主体不改形。桌面版展示复用原图标，不加终端框，不据此推断或改变 Agent 的运行状态。

- `AgentBrandCodex`：OpenAI 官方 Blossom，来自 [OpenAI 品牌资源](https://openai.com/brand/) 的 `OpenAI-Logos-2025.zip` 黑色 PNG，用于识别 Codex；以模板方式适配深浅背景。
- `AgentBrandClaude`：来自已安装官方 Claude 桌面版的 `Contents/Resources/electron.icns`，等比导出 PNG，用于识别 Claude Code。
- WillDeep：复用仓库已有 `AboutAppWillDeepIcon`，不复制另一份资源。

所有品牌标识归各自权利人所有。未知名称或资源加载失败时显示名称，不猜测品牌，也不改变状态识别或输入权限。
