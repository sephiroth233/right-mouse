# T016 Open With Host 集成检查

## 目录

- [范围](#范围)
- [自动检查](#自动检查)
- [运行方式](#运行方式)
- [参考](#参考)

## 范围

检查使用真实 `HostController.submit(_:interactive:)`、命令账本、`ApplicationLauncher.plan` 和回执状态转换。夹具全部位于随机临时目录。只有最终 `NSWorkspace` 应用启动边界通过 `openApplication` 注入为调用记录器，因此不会启动本机 Terminal、Visual Studio Code 或自定义应用。

该检查证明 Host 在 OS 边界前的规划、交互次数、URL 交付参数和回执行为；它不构成 Visual Studio Code 真机 UI、应用签名或系统权限验收证据。

## 自动检查

入口：`runOpenWithHostChecks() async throws -> Int`

文件：`tools/RightMouseHostCheck/OpenWithHostChecks.swift`

覆盖：

- 跨目录文件只请求一次项目目录，并只向应用交付用户选择的唯一项目目录。
- 取消项目目录选择时不调用应用启动边界，回执终态为 `cancelled`。
- 单文件及同父目录多文件保持文件语义，不显示项目目录选择器。
- 目录选择器异常返回文件时，在应用启动前以 `invalidDestination` 拒绝。
- 应用启动边界报错时，回执为 `failed`，不会记录为成功。
- 最近目标 token 指向目录 A 而请求提示 URL 故意指向另一个现存目录 B 时，只向应用交付书签解析出的 A 一次。
- 自定义 URL 应用收到一个标准 URL 批次；成功提示只声明已经交给应用。
- 成功的打开方式请求不会伪装成文件操作任务行。

## 运行方式

将 `OpenWithPlanning.swift`、`OpenWithInteraction.swift`、`OpenWithHostChecks.swift` 加入 Host 检查编译源，并在异步检查入口累加：

```swift
total += try await runOpenWithHostChecks()
```

2026-09-23 使用 Swift 6.4 Command Line Tools 将真实 `AppModel`、`HostController`、`ApplicationLauncher`、`OpenWithInteraction`、`OpenWithPlanning` 与本检查编译为独立临时可执行文件。执行结果为 `PASS open-with-host total: 30`。运行期间出现 FinderSync 可用性查询的沙盒 XPC 日志；该查询不参与这些断言，30 项 Host/账本断言均完成并通过。

整套 `scripts/check-host.sh` 在同一受限执行环境中还会运行真实文件复制检查，该既有检查因 sandbox extension 失败而停止。因此这里记录的是已实际执行的独立 Open With Host 检查结果，不把未完成的整套 runner 声称为通过。

测试替换的是明确的 OS 启动边界。真机 AC-013 仍需安装正式签名构建后，以 Terminal、Visual Studio Code 和包含特殊字符的实际路径手工验证。

## 参考

- [Open With 规划器](../../../Apps/RightMouse/OpenWithPlanning.swift)
- [真实 Host 集成检查](../../../tools/RightMouseHostCheck/OpenWithHostChecks.swift)
- [AC-013 验收标准](../checklists/acceptance.md)
