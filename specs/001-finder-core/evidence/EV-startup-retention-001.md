# 首次启动恢复提示误报修复

2026-09-23，修复空数据首次启动出现 recoveryDetected 的问题。生产代码与回归提交为 `f2e1e90`，此前未解释的启动诊断差异已定位；这项修复不代表真实 Finder 或界面验收通过。

## 目录

- [1. 根因与修复](#1-根因与修复)
- [2. 验证结果](#2-验证结果)
- [3. 交付与剩余边界](#3-交付与剩余边界)
- [参考](#参考)

## 1. 根因与修复

首次启动时，HostController 在 Commands 目录不存在时构造 CommandLedger.directory。目录创建后，OperationRetention 再次构造预期目录 URL。在本机优化构建中，前者保留非目录标记且没有末尾斜杠，后者带目录标记和斜杠。两个 URL 的 standardizedFileURL.path 相等，但直接比较 standardizedFileURL 不相等。目录匹配检查因此失败，空数据启动被记录为需要恢复。

直接打开已存在的测试目录不会触发同一时序；Foundation 对临时目录 /var 别名的规范化也可能消除标记差异。这解释了先前复制数据及空临时目录检查为何没有复现，而使用工作区全新目录的完整宿主初始化能够复现。

修复只改变目录匹配方式：先要求账本 URL 为文件 URL，再比较标准化文件系统路径。后续原有的逐级 no-follow 打开、所有者、私有目录权限及文件内容检查继续执行。真正的目录不匹配、符号链接、损坏记录仍由原有回归检查拒绝，没有跳过保留策略或压制所有恢复诊断。

## 2. 验证结果

环境为 macOS 27 / arm64、Command Line Tools Swift 6.4，Swift 5 语言模式，macOS 14 编译部署目标。所有数据使用随机隔离测试目录；不改写用户实际数据。无 UI 探针使用真实 Core、AppModel、HostController 和保留器，并分别覆盖显式存储注入和开发 Bundle 标志下的目录解析。

| 检查 | 实际结果 | 证明范围 |
| --- | --- | --- |
| 完整宿主优化构建初始复现 | 显式存储与开发 Bundle 路径均产生 issues=1 | 重现原启动诊断差异 |
| 旧 guard 优化回归 | 5 项中 3 项失败，退出码 1 | 显式目录标记、真实首次保留结果和恢复事件均能捕获原缺陷 |
| 修复后同一优化回归 | 5 项通过，退出码 0 | 仅有 hostStarted、configurationLoaded；空操作目录只有 host.lock |
| `scripts/check-host.sh` | 356 项通过，退出码 0 | 原有 351 项和新增 5 项首次启动回归；包括真实错误目录及不可信记录仍被拒绝 |

新增回归入口为 `runRetentionStartupChecks()`，已纳入标准宿主检查。脚本先切换到仓库根目录，测试在 `.build` 下创建 UUID 目录并自动清理，避免临时目录别名掩盖问题。测试释放宿主后才清理其私有账本。优化对照仅在隔离构建副本恢复旧 guard，没有回滚生产源码。

调查原始输出保存在本次工作区的 `.build/retention-host-opt-probe/`：`instrumented-report.txt`、`startup-before-report.txt`、`startup-after-report.txt`。这些是忽略的本机调查产物；可持续回归依据为已提交测试源码与标准宿主检查入口。探针中的 FinderSync 查询曾收到沙盒 XPC 限制日志，以上断言不依赖查询结果，不能用来证明扩展状态可访问。

## 3. 交付与剩余边界

`scripts/package-app.sh --development` 重新构建成功，宿主与嵌入扩展的 ad-hoc 签名结构校验通过。开发 ZIP 为 `dist/RightMouse-0.1.0-development.zip`；SHA-256：`c9084accceed06a054aba214b02dd54b230ef539623bf7eacd65dedc2a570c84`。仅凭该结果不宣称 App Group 授权或公证通过。

文件传输引擎没有在本轮修改；304 项核心和 15 项真实 APFS 双卷结果沿用[来源隔离修复](EV-source-isolation-001.md)与[双卷检查](EV-real-volume-001.md)，本轮没有将它们重复计为新执行。

真实 Finder 共享通信仍缺有效签名授权；最新界面的液态玻璃、居中、键盘与 VoiceOver 仍缺原生 UI 验收；最低 macOS 版本、实际外盘拔出和正式公证继续未测。31 条用例的部分证据与逐项剩余范围已关联到 [traceability.json](../traceability.json)，不因本项修复将完整用例自动标记 PASS。

## 参考

- [保留策略实现](../../../Apps/RightMouse/OperationRetention.swift)
- [首次启动回归](../../../tools/RightMouseHostCheck/RetentionStartupChecks.swift)
- [宿主检查脚本](../../../scripts/check-host.sh)
- [原始未解释现象](EV-source-isolation-001.md#启动验证边界)
- [验收清单](../checklists/acceptance.md)
