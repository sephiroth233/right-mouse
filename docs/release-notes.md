RightMouse 原生 macOS Finder 右键增强工具，本次提供 Apple Silicon 和 Intel 两种安装包。

## 0.2.1 更新

- 新建、复制、剪切粘贴、移动与打开方式正常完成后静默，不再弹出任务结果窗口。
- 移除操作历史入口；临时通信记录在请求失效且操作安全结束后清理，保留必要的冲突提示和异常文件核对。
- 登录启动时后台运行，不自动打开设置或显示 Dock 图标；手动打开应用仍显示设置。
- 关闭最后一个窗口后隐藏 Dock 图标，后台继续提供 Finder 功能。
- 通用设置新增“在菜单栏显示图标”，修改立即生效并保存；可通过 Spotlight、Applications 或 Finder 设置入口找回界面。

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

这是未经过 Apple 公证的本机预览版，使用和构建均不需要 Apple Developer 账号。最低编译目标为 macOS 14；两个架构已在 macOS 26 的 CI 上通过自动检查，此前真实 Finder 交互在 macOS 27 上完成本机验收；本次窗口生命周期通过隔离预览验证，真实注销登录与其他系统环境仍需验收。
