# 本机 Agent 项目导入

项目栏右侧的导入图标打开选择窗口，先按来源、名称或目录筛选，再勾选导入。已有项目标记为“已导入”，可手动选择未列出的文件夹。只加入 QTerm 项目分组，不复制会话、凭据或模型配置，不启动 Agent；当前终端和焦点保持不变。点击尚无终端的项目时才新建本地 shell。

## 数据来源

| 工具 | 读取的项目元数据 |
| --- | --- |
| Claude Code | `~/.claude.json` 的 projects 键及 `~/.claude/projects` 日志头部的 cwd |
| Codex | `~/.codex/.codex-global-state.json` 的工作区路径与 local-projects；sessions 中 session_meta.payload.cwd |
| WillDeep | `~/Library/Application Support/WillDeep/projects.json` 的 displayName/folderPaths，以及 `~/.willdeep/sessions/*.json` 的 workspace |
| Qoder | `~/.qoder/projects` 的 JSONL cwd |
| WorkBuddy | `~/.workbuddy/projects` 的 meta.json cwd，及兼容的 JSONL cwd |
| DeepSeek Harness / dsh | `~/.dsh` 下 workspace JSON 单元及 workspaces 逐记录格式；默认存储为 `storages/workspace/workspaces/*.json`，读取 version=2 的 record.path/title |

尊重 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`QODER_CONFIG_DIR`、`DSH_HOME` 的绝对路径覆盖。没有记录或目录已删除时不会出现候选项。多目录项目按每个目录分别导入；项目目录的连字符不会通过历史目录名反解，避免路径歧义。

dsh 格式依据官方 [workspace spec](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/workspace/workspace/src/spec.ts) 和 [JSON 存储](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/storage/storage-json)；本机安装的 `@deepseek-ai/dsh@0.2.1-rc.2` 包已核对存储声明与逐记录封装。

## 去重和读取边界

- 路径必须是仍存在的绝对本地目录，规范化 `..`、尾斜杠并解析符号链接。相同目录合并工具来源，同名但不同目录保留为两个项目。
- 导入时再次检查路径及已有分组，重复点击和多来源记录不会创建重复项目。布局一次性校验后保存；导入期间目录删除则跳过。
- 扫描在后台任务中执行，单棵记录目录最多遍历 4,000 项、深度最多 8 层，跳过 node_modules、subagents、logs、cache、blobs 和符号链接条目。
- JSON 文件最多 8 MiB，JSONL 只检查前 128 KiB 中的前 32 行。损坏或超限文档跳过并显示提示；达到遍历上限也会明确提示，可手动选目录补充。
- 不读取 auth、credentials 或对话正文作为路径来源；不将第三方记录中的内容当作命令执行。应用不会扫描整个磁盘寻找项目。

## 侧栏

“项目”标题、新建和导入图标共用一行；整个项目区可收起为一行，当前终端继续显示；单个默认分组不再重复显示标题。点击项目标题选择该项目，再次点击可折叠/展开其标签。导入得到的空项目仅占一行，首次点击才创建 shell。
