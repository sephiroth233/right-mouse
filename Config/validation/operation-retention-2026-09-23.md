# 操作记录保留策略检查

日期：2026-09-23。`OperationRetention(paths:ledger:).prune(now:)` 使用宿主已持有的 `CommandLedger` 锁实例，在启动、尚未接受新任务时同步运行。调用方先清除会话 pending-move，再执行清理与历史恢复。返回扫描请求数、清理请求数、删除记录数、保留请求数和问题数，不返回用户路径。

## 目录

- [清理规则](#清理规则)
- [文件安全与中断](#文件安全与中断)
- [验证](#验证)
- [参考](#参考)

## 目录

- [清理规则](#清理规则)
- [文件安全与中断](#文件安全与中断)
- [验证](#验证)
- [参考](#参考)

## 清理规则

请求创建时间和终态回执更新时间均早于 `now - 30 天` 才进入候选；恰好 30 天仍保留。文件 mtime 仅用于检测校验后变化，不决定保留期限。

`accepted/planning/running/waitingForUser/cancelling/needsReview` 不按年龄清理。回执或逐项错误含 `recoveryRequired/sourceRetained`、逐项状态含 `sourceRetained/needsReview` 的记录继续保留。

普通无逐项结果动作，以及明确成功或明确无逐项副作用而失败的创建操作，可以在回执一致时清理。转移任务需要 Followups、Transfers、回执与 Commands 的完整一致证据。记录版本、ID、摘要、项目状态、模式、来源/目标元数据及撤销位置不一致时保留。

重试链接组成无向连通分量。任一成员近期、活动、缺失或证据不完整时，整条关联链保留；所有成员均为过期且证据完整的终态时，整组清理，不永久保留普通已结束的重试链。

本轮采取以下保守边界：有任何撤销开始记录的任务（包括已完成撤销）、没有完整后续记录的终态转移、旧版仍含 `stagingURL` 的转移继续保留。新引擎只有成功清理暂存后才清空该字段。这里不声明所有终态都自动在 30 天后删除。

## 文件安全与中断

仅处理 Commands、Receipts、Inbox、Followups、Transfers、Reviews 下经过校验的固定 UUID JSON 文件。应用根目录先检查非符号链接，再用 Darwin `realpath` 得到物理路径；后续目录和文件使用目录描述符与 `openat/O_NOFOLLOW`，拒绝符号链接、硬链接、非普通文件、错误所有者或过宽权限。删除前再次验证设备号、inode、字节和 mtime，使用锚定目录的 `unlinkat` 并同步目录。

不会遍历或删除 JSON 内记录的来源、目标或暂存路径，只验证它们的元数据格式。损坏的 Commands/Transfers 按项保留，不阻止无关且证据完整的任务清理。Followups 可能保存唯一的单向重试关联：任何无法解码、未知 schema 或文件名/请求 ID 不匹配的 Followup 都会禁用整轮清理，防止误将未知子任务当成独立任务清除。schema 1 且 ID 一致、能够可信重建关联但结果不完整的 Followup，仅保留其所在组件。根目录或私有目录本身不可信时也停止本轮清理。

每个关联组件分三阶段删除：先删除全部普通证据（包括所有成员 Receipts、Transfers、无 retry 链接的 Followups、Inbox、Reviews），再删除保存 retryRequestID 的父 Followups，最后删除所有 Commands。删除任何关联边之前，每个成员的 Receipt 都已消失，因此即使中断后边丢失，剩余成员也无法因被误视为独立完整任务而进入清理。

若中途失败或进程退出，可能留下缺失侧车的 Commands；下一次启动会保守保留这些记录供核对。清理不是跨多个文件的事务，也不会重放旧操作。fixture 可通过默认 nil 的 `afterRemoval` hook 在每次实际删除后模拟中断，生产入口不使用该 hook。

## 验证

`tools/RightMouseHostCheck/RetentionChecks.swift` 提供 `@MainActor runRetentionChecks() async throws -> Int`。独立编译至 `.build/retention-checks/RetentionCheck`，**56 个检查通过**，包括：30 天边界、新近 mtime 不延长过期状态、全部非终态与 needsReview、两类不确定错误、撤销不确定、来源保留、近期和缺失 retry 子任务、完整过期重试组件、坏记录、坏或缺失 sidecar、坏 journal、staging 引用、文件及目录符号链接、用户文件和暂存内容不变、重复清理、ledger 路径不匹配，以及去重记录删除后旧请求仍被 120 秒时效规则拒绝。

转移夹具使用真实文件引擎在隔离临时目录执行。工具 sandbox 内会阻止协调操作，因此获准在 sandbox 外运行同一测试二进制；未改用户隐私设置或真实共享容器。此记录验证保留逻辑，不替代真实 App 启动或 Finder 通信验收。

## 参考

- [数据与保留模型](../../specs/001-finder-core/data-model.md)
- [保留实现](../../Apps/RightMouse/OperationRetention.swift)
- [保留检查](../../tools/RightMouseHostCheck/RetentionChecks.swift)
- [文件引擎](../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/FileTransferEngine.swift)

新增回归覆盖两成员重试链在 7 个有剩余 Commands 的逐文件删除位置中断；每次检查实际停止位置、下一轮所有剩余成员均保留，以及删关联边前全部成员 Receipts 已删除，共 21 项。另用不可解码、未知 schema、ID 不匹配三类 Followup 各验证“全轮停止”与“移除坏证据后正常清理”，共 6 项。原单坏侧车夹具改为 schema/ID 可解码但结果不完整，继续验证局部组件保留。

## 参考

- [数据模型与保留策略](../../specs/001-finder-core/data-model.md)
- [保留实现](../../Apps/RightMouse/OperationRetention.swift)
- [独立检查入口](../../tools/RightMouseHostCheck/RetentionChecks.swift)
- [后续操作数据结构](../../Apps/RightMouse/TaskFollowupStore.swift)
