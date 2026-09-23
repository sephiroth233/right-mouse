# 可视化菜单管理施工与交付验收

日期：2026-09-23。关联 T008、T017；Apple Silicon / macOS 27 本机预览。

## 目录

- [实现](#实现)
- [验证](#验证)
- [交付](#交付)
- [边界](#边界)
- [参考](#参考)

## 实现

按照已批准的效果图重构原生菜单管理：每条操作选择一级菜单、子菜单或隐藏；提供搜索、全部/一级/隐藏筛选、分类折叠及批量设置、一级排序、逐层场景预览和默认布局恢复。列表独立滚动，窗口维持默认 960×680。隐藏配置写入持久化文件和认证菜单快照；宿主拒绝过期菜单对已隐藏操作的执行。

旧配置缺少 hiddenEntryIDs 时默认空列表。恢复某个旧禁用组内的单项不会同时启用所有兄弟项。旧平铺布局在修改位置时保留其他一级操作。内部任务引擎保留，五个侧栏入口不变。

## 验证

| 层次 | 结果 | 本机原始记录 |
| --- | --- | --- |
| 核心规则及存储 | 384 项通过；新增 14 项覆盖隐藏、恢复、批量、旧配置、快照与认证执行拒绝 | `.build/menu-editor-core.log` |
| 宿主 | 472 项通过 | `.build/menu-editor-host.log` |
| 最终 XPC 集成 | 18 项通过，含身份边界、菜单握手、真实创建、重放去重、过期拒绝、服务重启恢复 | `.build/menu-editor-xpc.log`、`.build/menu-editor-final/xpc-checks/results.json` |
| 原生编译及签名 | 最终构建成功、嵌套签名严格验证通过 | `.build/menu-editor-final-build.log` |
| 界面与实际菜单 | 搜索、隐藏恢复、排序按钮与拖动、分层预览及场景切换通过；真实 Finder 五条一级操作且隐藏 Shell 缺席 | [设计验收](../../../design-qa.md)、`.build/menu-editor-finder-ax.txt` |
| 安装包 | DMG 镜像校验、安装副本签名及认证快照读取通过 | `.build/menu-editor-package.log`、`.build/menu-editor-installed-menu.json` |

UI 夹具仅使用 `.build/menu-editor-acceptance`；XPC 操作仅在 `.build/finder-xpc-acceptance/7d316046-b6cf-4969-86ce-f74d84afd7a6` 创建文件。配置测试过程中保留 Shell 隐藏；退出隔离应用后恢复正常用户配置。

## 交付

- 包：`dist/RightMouse-0.2.0-local-arm64.dmg`。
- SHA-256：`42609faeee2b25a01ae5480c7a963d36a4a8a9e322749412f23b4202f6a8ebee`。
- 本机构建公开证书指纹：`ade37b1d69a07cf1331fa211bd0514bf9c19e0a5`。这是构建身份，不是 Apple 公证。
- 从只读 DMG 更新并启动 `.build/dmg-installed/RightMouse.app`；旧应用移至同目录的 `RightMouse-before-menu-editor.app`，便于回退。
- 安装后只登记一个扩展，UUID `7075E405-854C-4E25-814A-61E7384EE4CD`，路径指向安装副本。认证菜单读取成功，保留原有 6 个模板、4 个应用，一级顺序 TXT / 完整路径 / Markdown / 终端 / VS Code，隐藏列表为空。
- 分步提交：`1ba104f` SDD 契约、`e726769` 核心规则与兼容、`5bb08e6` 原生菜单编辑界面。文档及截图在后续独立提交归档。

## 边界

当前包替代此前同名 DMG，旧证据中的散列是历史记录。此次只交付本机预览，未新增其他 macOS、干净机器、互联网下载 Gatekeeper 或完整深色/VoiceOver 验收；T017/T021 的整体系统矩阵不因此勾选完成。

## 参考

- [本机 XPC 契约](../contracts/local-xpc.md)
- [批准效果图](../../../docs/design/menu-editor-reference.png)
- [实际原生界面](../../../docs/design/menu-editor-actual.png)
- [历史完整菜单验收](EV-full-finder-menu-001.md)
- [本机安装说明](../../../docs/local-install.md)
