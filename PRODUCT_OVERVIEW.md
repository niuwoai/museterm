# Product Overview

> 最后更新：2026-06-30 | 当前版本：v1.2.0-rc17

## 项目简介

MuseTerm 是一个轻快的 macOS 多标签终端应用，使用 SwiftUI 构建外壳界面，并通过 SwiftTerm 提供本地 shell 终端能力。

## 核心功能

- 多标签终端：左侧纵向标签列表，支持新建、切换、关闭标签。
- 标签快捷键：支持 `Cmd+T` 新建、`Cmd+Shift+[` / `Cmd+Shift+]` 前后切换，以及 `Cmd+1` 到 `Cmd+9` 直达标签。
- 快速建签：预热下一份终端控制器和备用 shell，并延后补位以减少新建标签后的主线程阻塞。
- 本地 shell：每个标签启动一个独立登录 shell。
- 标签保活：切换标签时终端渲染视图常驻，避免已有输出丢失或变空白。
- 终端状态：自动同步终端标题、当前目录和进程退出状态。
- 标签标题：本机会话优先显示当前目录，远端/SSH 标题保留 `user@host` 便于识别。
- 皮肤系统：从 MuseMail 的视觉体系迁移，针对终端场景提供浅色与深色皮肤。
- 字符配色：支持 Apple、Tango、Solarized、Dracula、One Dark、Nord 等经典 ANSI palette。
- 毛玻璃配置：支持启用/关闭、材质选择、玻璃强度、终端底色透明度、染色和柔光。
- 字体配置：支持从已安装字体中搜索选择主字体和回退字体。
- 排版配置：支持字号和行高调节。
- 设置窗口：支持 `Cmd+,` 快捷键，并按外观、字体、毛玻璃和行为分组。
- 紧凑侧栏：底部仅保留设置图标入口，减少常驻控件占用。

## 技术栈

- 应用：SwiftUI + AppKit
- 终端内核：SwiftTerm
- 平台：macOS 13.0 及以上（覆盖 macOS 13.7）
- 本地化：`Localizable.strings`

## 运行

- 打开 `museterm.xcodeproj`
- 选择 `museterm` scheme
- 在 Xcode 中运行

## API 概览

本项目当前没有服务端 API。版本号通过应用内 `AppVersion` 和 Xcode `MARKETING_VERSION` 保持一致，发布最低系统版本通过 Xcode `MACOSX_DEPLOYMENT_TARGET` 管理。

## 已知问题 / 待办

- [ ] 增加快捷键：新建标签、关闭标签、切换标签、打开设置。
- [ ] 增加终端配色 palette 的完整 16/256 色映射。
- [ ] 增加标签重命名、启动目录和自定义启动命令。
- [ ] 增加导出滚屏内容和搜索面板。
