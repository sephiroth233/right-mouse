# 来源路径竞争与隔离恢复

本轮针对 AC-024 的来源替换竞争，并补充 AC-008 撤销、AC-020 硬链接和 AC-022 恢复证据。关联任务为 T015、T019、T020；此前正常路径和阶段前注入通过，不足以覆盖核验与实际重命名之间的窗口。

## 目录

- [问题与处理](#问题与处理)
- [恢复与保留](#恢复与保留)
- [验证结果](#验证结果)
- [启动验证边界](#启动验证边界)
- [参考](#参考)

## 问题与处理

此前同卷移动和撤销在核验后按路径重命名，重命名后没有再次确认被移动对象是否仍是原对象。新增提交后检查目标父目录、每项稳定身份、内容与相关元数据；只忽略重命名本身会改变的 ctime。若对象被替换，不报告完成，不生成可用撤销凭据，也不按路径盲目移回。

复制模式也必须把提交后的内容及元数据与已验证来源快照比较。定向复现在未补充此比较的版本中得到“copy target replacement was reported as completed”的失败；补充后，同一场景返回 needsReview，原来源与替换目标均保留。此失败发生在独立检查程序中，不是应用启动崩溃。

跨卷移动此前在核验来源后直接删除来源公开路径，其他进程可能在核验和删除之间替换该名称。现在先保存隔离意图，把来源以禁止覆盖的重命名移入来源同父目录下的私有容器，再完整核验隔离对象与已提交目标。只有原对象及内容仍匹配时才清理隔离副本；原路径后续出现的新文件不属于删除范围。

私有目录隔离减少普通路径使用者造成的竞争，但不声称能对抗持有文件描述符或主动访问同用户私有目录的恶意进程。无法确认对象或内容时保留证据并要求核对；不会用反复 stat 宣称获得跨进程原子锁。

硬链接清理还有一项自身造成的变化：删除第一条链接会改变相同 inode 其他名称的 ctime。只对本轮已成功 unlink 的相同 device/inode 放宽该字段，其他对象仍用完整身份；内容、元数据、大小和 mtime 继续核对。硬链接复制与跨卷移动已纳入本轮定向检查。

## 恢复与保留

journal 新增可选的 sourceCleanupURL、sourceCleanupIdentity、sourceCleanupContainerIdentity 和 sourceCleanupState。状态包括 isolating、isolated、completed 和 needsReview；旧无字段日志保持兼容。隔离操作先记录意图，再移动，再记录观察结果，成功清理后移除路径引用。

恢复页单独显示“待核对的来源副本”，提供路径查看和定位，不提供自动删除或移回。记录保留器遇到隔离引用或不确定状态时保留关联任务证据，即使原终态记录已超过 30 天。人工核对不改写原任务结果，也不自动删除隔离内容。

## 验证结果

| 检查 | 实际结果 | 边界 |
| --- | --- | --- |
| 完整核心回归 | 304 项通过，退出码 0 | 包含新增 6 组竞争与硬链接检查 |
| 完整宿主回归 | 351 项通过，退出码 0 | 保留策略从 56 增至 66 项；另新增 4 项来源副本恢复检查 |
| 真实 APFS 双卷 | 当前源码重新执行 15 项通过，退出码 0 | 包括正常移动、取消保源、实际 ENOSPC；不替代拔盘或其他文件系统 |
| 原生开发包 | 宿主与扩展编译、ad-hoc 签名结构验证通过 | 不代表 App Group 已授权或正式公证 |

新增定向检查包含复制提交后替换、同卷紧邻 rename 前后替换、跨卷紧邻来源隔离 rename 前替换、隔离后原路径新建对象、撤销替换，以及硬链接复制与跨卷清理。核对页恢复测试确认原始回执与 journal 不被重写，隔离副本、原路径新对象和已提交目标字节都保留。相关程序只使用随机临时夹具；文件协调检查在获准访问系统服务的环境执行。受限环境中的文件协调错误没有计为通过。

开发 ZIP：`dist/RightMouse-0.1.0-development.zip`。SHA-256：`0150b5268343147d2a717d1ed8e30fe9664879158f8662d97ad31b0aa5572a96`。

## 启动验证边界

本轮重新读取系统状态：签名身份仍为 0 个有效身份，开发工具仍指向 Command Line Tools。对已有开发进程和独立标识的最新开发副本分别采样，均处于正常 AppKit 事件循环，未见初始化或文件协调阻塞。独立副本使用工作区临时数据目录，记录了 hostStarted 与 configurationLoaded；没有修改原用户配置。

原生验证工具重置后仍报告 cgWindowNotFound。进程和初始化日志只能证明启动代码执行，不证明窗口可见、液态玻璃效果、居中几何或 VoiceOver 可用。本轮不将这些 UI 验收标为通过。临时副本没有注册业务 URL scheme，也没有包含 Finder 扩展，不作为 Finder 共享通信证据。

隔离副本的空数据启动还记录过一条 recoveryDetected。将其完全测试数据复制并保留权限后，当前保留器返回 scanned/pruned/removed/retained/issues 全部为 0；单根、双根空布局回归也未复现。当时未解释的诊断差异已在后续定位为目录 URL 标记比较误报，见[首次启动修复](EV-startup-retention-001.md)；未为消除提示而放宽安全检查。临时副本进程已结束，原 RightMouse 进程未被终止。

## 参考

- [文件引擎](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/FileTransferEngine.swift)
- [文件系统校验](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/TransferFileSystem.swift)
- [恢复模型](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/TransferTypes.swift)
- [宿主来源恢复检查](../../../tools/RightMouseHostCheck/SourceRecoveryHostChecks.swift)
- [竞争窗口检查](../../../tools/RightMouseCheck/RaceChecks.swift)
- [保留策略检查](../../../tools/RightMouseHostCheck/RetentionChecks.swift)
- [验收用例](../checklists/acceptance.md)
