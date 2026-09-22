# EV-T001：开发环境与身份基线

记录本机真实工具链、签名能力和当前可执行的构建路径，作为后续验证的环境证据。

日期：2026-09-22；状态：环境核验完成，产品兼容与正式分发未完成。

## 目录

- [1. 实际结果](#1-实际结果)
- [2. 已采用的施工决策](#2-已采用的施工决策)
- [3. 剩余验证](#3-剩余验证)
- [参考](#参考)

## 1. 实际结果

| 检查 | 结果 |
| --- | --- |
| 系统 | macOS 27.0，build 26A428，arm64 |
| Swift | Apple Swift 6.4，language mode 5，部署目标 macOS 14.0 |
| active developer directory | /Library/Developer/CommandLineTools |
| 完整 Xcode | `xcodebuild -version` 返回需要完整 Xcode；Spotlight bundle 查询未发现安装 |
| SDK | CLT MacOSX SDK 包含 SwiftUI、AppKit、FinderSync；可编译原生应用与扩展 |
| XCTest | CLT 缺失 XCTest 模块，`swift test` 未通过；不能计入测试成功 |
| 签名身份 | `security find-identity -v -p codesigning` 显示 0 valid identities |
| Finder 登记 | 基线首次查询无登记项；后续开发扩展已登记且系统启动进程，见下方接入记录 |
| Git | 已初始化 main，SDD 基线提交 8df543f |

## 2. 已采用的施工决策

原生源代码可使用现有 `swiftc` 编译，开发包采用 ad-hoc 签名；正式发布仍保留 Developer ID/公证门禁。标准 Xcode 工程同时生成，以便完整工具链可用后运行原生 test target。独立的 `RightMouseCheck` 执行同一核心库的真实临时文件夹具，明确不替代 Finder/TCC/签名和最低系统测试。

开发 bundle ID 固定为 `cn.rightmouse.RightMouse`，扩展为 `cn.rightmouse.RightMouse.FinderExtension`。App Group `group.cn.rightmouse.shared` 是开发占位，可由构建配置替换；当前没有真实 Team ID/能力配置，不能宣称该容器已被正确授权。UI 验证使用项目 `.build/ui-runtime` 独立数据目录。

## 3. 剩余验证

G0 尚未通过：开发扩展已在本机真实加载，App Group 路径查找成功，详见 [Finder 接入记录](../../../Config/validation/finder-load-2026-09-22.md)。共享读写、实际菜单命令、扩展触发宿主冷启动和权限传递仍缺少完整证据。可以继续独立核心和界面开发，但不能把这些进展当成原生接入通过。macOS 14、其他架构、真实外置卷和公证环境也尚未提供或验证。

## 参考

- [调研决策](../research.md)
- [施工任务](../tasks.md)
- [Apple 分发机制](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
