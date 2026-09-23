RightMouse 原生 macOS Finder 右键增强工具，本次提供 Apple Silicon 和 Intel 两种安装包。

## 下载选择

| 你的 Mac | 安装包后缀 |
| --- | --- |
| Apple Silicon（M 系列） | `local-arm64.dmg` |
| Intel | `local-x86_64.dmg` |

请在下方 Assets 中下载 DMG。`.sha256` 是对应校验文件，`build-info-*.json` 记录源码提交和构建环境。

## 主要功能

- 从 Finder 右键新建文件，支持内置和自定义模板。
- 复制路径、文件名及终端转义路径。
- 剪切粘贴、复制到或移动到指定目录，同名文件询问处理方式。
- 使用终端、VS Code 或自定义应用打开文件与目录。
- 自定义一级菜单、子菜单与隐藏项，支持搜索、排序和菜单预览。

## 安装

1. 打开 DMG，将 RightMouse.app 拖入 Applications。
2. 启动应用；若 macOS 阻止运行，在「系统设置 → 隐私与安全性」中选择「仍要打开」。
3. 在应用「权限与诊断」中打开扩展设置，启用 RightMouse Finder 扩展。
4. 等待显示「已连接」，然后在 Finder 中右键使用。

详细安装、升级与排障步骤见 [安装说明](https://github.com/sephiroth233/right-mouse/blob/main/docs/local-install.md)。升级前退出应用，并替换整个应用包。

## 版本状态

这是未经过 Apple 公证的本机预览版，使用和构建均不需要 Apple Developer 账号。最低编译目标为 macOS 14；两个架构已在 macOS 26 的 CI 上通过自动检查，真实 Finder 交互在 macOS 27 上完成本机验收，其他环境仍需验证。
