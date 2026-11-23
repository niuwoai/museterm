# @niuwoai/museterm-plugin

MuseTerm 插件的 SDK。当前是 `0.1.0-rc1`，只包含插件清单的 TypeScript 类型、JSON Schema 和校验。它不连接 MuseTerm，不下载命令行，也不执行插件代码。

应用侧的插件宿主还没有实现。插件的进程、权限和安装规则见仓库里的 `docs/PLUGIN_SYSTEM.md`。

这个包与 `@niuwoai/museterm` 不是同一个东西。后者安装本机命令行，并通过 MCP 操作已经打开的 MuseTerm。

## 安装

```bash
npm install --save-dev @niuwoai/museterm-plugin@rc
```

需要 Node.js 22 或更高版本。发布标签是 `rc`，省掉 `@rc` 时 npm 会去找还不存在的 `latest`。

## 校验一份清单

```typescript
import { checkPluginPackage } from "@niuwoai/museterm-plugin"
import packageJson from "./package.json" with { type: "json" }

const issues = checkPluginPackage(packageJson, { appVersion: "1.262.0-rc2" })
```

`issues` 为空才表示这份 `package.json` 能被将来的宿主安装。校验只看传入的对象，不读插件目录，也不启动进程。

`definePlugin` 用同一套规则检查清单本身，适合写插件时提前发现缺字段。它不向应用注册任何东西。

清单是 `package.json` 的 `museterm` 字段。用户能看见的文字都要同时给出 `en` 和 `zh-Hans`。权限只有 `palette`、`terminal.fill`、`ai.suggest` 和 `recording.observe`。

## 许可

MuseTerm 为专有软件，本包随应用仓库分发，未授予再分发许可。
