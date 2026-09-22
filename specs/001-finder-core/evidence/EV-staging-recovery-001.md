# 孤立暂存检查与显式清理

## 目录

- [范围](#范围)
- [安全模型](#安全模型)
- [核心 API](#核心-api)
- [自动检查](#自动检查)
- [参考](#参考)

## 范围

文件引擎在创建 `.rightmouse-<itemID>` 后立即把暂存目录的 device、inode、kind、父目录身份、operation ID 和 item ID 写入原 transfer journal。旧记录缺少归属身份时仍可展示位置与占用，但不能取得清理令牌。

检查和清理仅处理原 journal 明确关联的单个暂存目录，不扫描或删除其他隐藏文件。用户源、最终目标和任意暂存路径之外的内容不属于清理对象。

## 安全模型

- 只有 `staging` 或 `verified` 阶段、没有 result、最终目标尚未出现、来源身份未变化的记录可生成清理令牌。
- 暂存目录必须是目标目录的直接子项，名称严格等于 `.rightmouse-<itemID>`；中断恢复时只接受确定性的 `.rightmouse-cleanup-<itemID>`。
- 目标父目录、暂存目录均核对持久化 device、inode 和 kind；暂存根必须由当前用户拥有且权限不开放给 group/other。
- 清理先持久化 `requested`，再在同一父目录中使用 no-replace rename 隔离；递归删除使用目录描述符和 nofollow 检查，不跟随后代符号链接，也不跨卷。
- 删除后才持久化 `completed`。重命名或删除失败写入 `needsReview` 并保留现场；目录已删除但完成记录写入失败时返回 `RECOVERY_REQUIRED`，不报告成功。

## 核心 API

```swift
await engine.inspectStagingRecovery(operationID: id) -> StagingRecoveryInspection
try await engine.cleanupStaging(token) -> StagingCleanupResult
```

UI 只能为 `StagingRecoveryDisposition.cleanupAllowed(token)` 显示确认清理入口。`legacyEvidenceOnly` 和 `retainedForReview` 仅展示占用和原因。

## 自动检查

入口：`runStagingRecoveryChecks() async throws -> Int`

使用 Swift 6.4 Command Line Tools 在独立目录 `/private/tmp/rightmouse-staging-recovery` 编译全部 Core 源码和检查入口。2026-09-23 实际结果：

```text
PASS staging-recovery total: 17
```

覆盖真实私有暂存目录及 journal 的重启检查、按 operation ID 限定检查、占用统计、显式成功清理、用户源和目标不变、后代符号链接不跟随、检查后 journal 变化使 token 失效、非目标直接子目录拒绝、旧记录禁止清理、目录替换拒绝、暂存根符号链接拒绝、目标已出现、来源变化，以及 `requested` 重命名后中断的重启续清理。

## 参考

- [暂存恢复模型](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/TransferTypes.swift)
- [暂存检查与清理](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/StagingRecovery.swift)
- [文件传输引擎](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/FileTransferEngine.swift)
- [独立检查](../../../tools/RightMouseCheck/StagingRecoveryChecks.swift)
