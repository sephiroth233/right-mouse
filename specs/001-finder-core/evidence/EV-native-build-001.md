# 原生开发包整合验证

本记录固定宿主、Finder 扩展和开发 ZIP 的实测结果，区分构建成功与系统功能验收。

日期：2026-09-22；状态：开发构建通过，完整端到端验收未完成。

## 目录

- [1. 构建结果](#1-构建结果)
- [2. 实际界面检查](#2-实际界面检查)
- [3. 宿主集成检查](#3-宿主集成检查)
- [4. 剩余验证](#4-剩余验证)
- [参考](#参考)

## 1. 构建结果

运行 `python3 Config/generate-project.py`，生成包含 8 个宿主 Swift 文件、1 个扩展入口、5 个核心 XCTest 文件的工程。`plutil -lint RightMouse.xcodeproj/project.pbxproj` 通过。

运行 `scripts/package-app.sh --development` 成功，Swift 编译宿主及真实 `.appex`；嵌入扩展与宿主分别签名，`codesign --verify --deep --strict` 通过。产物为 `.build/native/RightMouse.app` 和 `dist/RightMouse-0.1.0-development.zip`。

本次 ZIP 的 SHA-256：`beb9faf3d0fc39df8d3e11252d6d7ab60f6aab652c0458a5be4372aad1fc6ce9`。后续重建可能产生不同字节，应重新记录校验值。

扩展在本机已被系统登记并启动，详见 [Finder 加载证据](../../../Config/validation/finder-load-2026-09-22.md)。本次采用 ad-hoc 开发签名，不能据此宣称正式分发或公证通过。

## 2. 实际界面检查

原生工具读取到了九个中文侧栏入口，实际切换了通用、菜单管理、新建文件、常用目录、打开方式、文件操作六页。通过 UI 启用紧凑模式、把新建文件分组改为“常用工具”，独立测试数据目录中的配置 revision 增长至 5，配置值与操作一致。

检查发现列表按钮的可访问性节点被合并、嵌套菜单预览缺项、中文任务状态未匹配图标，均已修改并编译通过。后续接入恢复详情页，包含来源/目标、位置观察、逐项人工核对及持久化确认。源代码编译不代表这些修改已完成原生交互复验。

## 3. 宿主集成检查

`scripts/check-host.sh` 编译产品中的真实 HostController、AppModel、ApplicationLauncher 和 RightMouseCore，以随机临时目录运行 16 项检查，全部通过。覆盖启动恢复为 needsReview、坏日志隔离、不重放未知操作、TXT/JSON 创建及回执、固定请求 ID 去重、复制和移动及逐项结果、排队取消和零文件副作用。

测试关闭创建后 Finder 定位，不使用用户剪贴板、应用打开、冲突弹窗或目录选择器，也不修改系统权限。详细复现说明见 [宿主检查入口](../../../tools/RightMouseHostCheck/README.md)。这些结果证明进程内调度与文件结果，不替代跨进程 Finder 接入和可见界面验收。

## 4. 剩余验证

原生自动化通道在权限诊断页检查期间断开，反复连接仍返回 `Sky Computer Use native pipe closed before response`。此前截图只得到缩略图，未取得可用于整体视觉验收的完整截图。修复后的列表操作、恢复详情页、键盘与 VoiceOver、授权撤回仍未完整验证。

真实 Finder 菜单到宿主的命令链路、跨进程 App Group 读写和冷启动尚未闭合；真实双卷故障、最低系统、完整 Xcode 的 test target 和正式签名公证也未通过。本记录不将对应整条 AC 标记为 PASS。

## 参考

- [构建配置](../../../Config/README.md)
- [核心检查证据](EV-core-checks-001.md)
- [验收清单](../checklists/acceptance.md)
