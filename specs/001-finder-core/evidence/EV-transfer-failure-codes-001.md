# 文件传输结构化失败码检查

## 目录

- [范围](#范围)
- [映射原则](#映射原则)
- [自动检查](#自动检查)
- [Host 接入](#host-接入)
- [参考](#参考)

## 范围

文件引擎为每个 `TransferItemResult` 保存可选的 `CommandFailure`，使 Host 能把具体失败码、中文说明和可重试属性写入逐项回执。字段为可选值，缺少该字段的旧 journal 与 sidecar 仍可解码。

检查只使用随机临时目录。权限场景使用真实不可写目录；磁盘满与卷断开使用引擎既有测试阶段注入分别产生 `ENOSPC` 与 `ENODEV`，没有修改真实磁盘或卷。

## 映射原则

- 来源消失映射为 `SOURCE_MISSING`；目标目录消失映射为 `INVALID_DESTINATION`，不混淆两者。
- 权限拒绝、磁盘空间不足和卷不可用分别映射为 `ACCESS_DENIED`、`NO_SPACE` 和 `VOLUME_UNAVAILABLE`。
- 来源变化、目标冲突与取消分别映射为 `SOURCE_CHANGED`、`DESTINATION_CONFLICT` 和 `CANCELLED`。
- 目标已经提交而来源仍存在时，结果保持 `sourceRetained`，失败码为 `SOURCE_RETAINED`；提交状态无法确认时使用 `RECOVERY_REQUIRED`，不鼓励自动重试。
- 未识别 I/O 保持不可重试的通用 `IO_FAILED`，不推测具体原因。

## 自动检查

入口：`runTransferFailureChecks() async throws -> Int`

文件：`tools/RightMouseCheck/TransferFailureChecks.swift`

2026-09-23 使用 Swift 6.4 Command Line Tools，在独立目录 `/private/tmp/rightmouse-failure-checks` 编译全部 `RightMouseCore` 源码及该检查。执行结果：

```text
PASS transfer-failure total: 21
```

21 项断言覆盖真实权限拒绝、真实来源缺失、注入 `ENOSPC`、注入 `ENODEV`、来源变化、冲突取消、目标占用、提交后来源保留、提交状态不确定、未知错误保守 fallback、目标消失上下文，以及不含 `failure` 字段的旧结果解码。

## Host 接入

构造逐项回执时优先使用引擎提供的结构化失败：

```swift
error: item.failure ?? legacyFallback(for: item)
```

旧 journal 的 `failure` 为 `nil`，因此 Host 应保留基于旧 `status` 和 `message` 的兼容 fallback。`sourceRetained` 和 `needsReview` 不应自动转换成可直接重试的普通 I/O 失败。

## 参考

- [失败映射](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/TransferFailureMapping.swift)
- [传输结果类型](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/TransferTypes.swift)
- [文件传输引擎](../../../Packages/RightMouseCore/Sources/RightMouseCore/FileOperations/FileTransferEngine.swift)
- [独立检查](../../../tools/RightMouseCheck/TransferFailureChecks.swift)
- [协议错误码](../../../Packages/RightMouseCore/Sources/RightMouseCore/Protocol/Command.swift)
