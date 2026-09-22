# 批量冲突宿主集成检查

日期：2026-09-23。检查入口为 `tools/RightMouseHostCheck/ConflictChecks.swift` 中的 `@MainActor runConflictChecks() async throws -> Int`，本次独立执行 **43 项通过，退出码 0**。

检查使用当前真实 `HostController`、Core 文件引擎、操作日志和任务模型。临时来源、目标、状态目录在结束后清理，冲突选择通过 `conflictPrompt` 注入，不创建 NSApplication 或真实弹框。输出目录独立使用 `.build/conflict-checks`，没有覆盖主任务的 `.build/host-checks`。

## 覆盖范围

| 场景 | 断言数 | 验证内容 |
| --- | ---: | --- |
| 单项保留、本批保留、本批跳过 | 12 | 两项冲突分别提示 2/1/1 次；已有目标字节不变；逐项结果正确；下一独立任务重新询问 |
| 用户取消、取消令牌、模拟超时、窗口不可用 | 17 | prompt 内观察持久化 `waitingForUser` 与任务模型“等待选择”；让出执行后等待状态仍正确；前一已完成项保留；冲突及后续项不写入；终态退出等待；超时有明确说明 |
| 等待期间替换来源父目录、目标目录 | 8 | 实际将目录移到旁边并创建替代目录；回答保留两份后身份检查拒绝；不产生编号副本；旧对象和替代对象均保留 |
| 等待状态恢复 | 2 | 用日志种入 `waitingForUser`；重建宿主后持久化为 `needsReview`；不重新执行、不弹框 |
| 等待日志写入失败 | 4 | 在运行状态已保存后把临时 Commands 目录设为 0500；第一项仍完成，后续等待写入失败；prompt 未被调用；任务需要核对且禁用撤销/重试；剩余项目无副作用 |

日志拒绝用的是夹具目录的真实文件系统权限，不是仅让函数返回假错误。结束时恢复权限并清理夹具。测试执行获准在工具 sandbox 外运行，使宿主为测试文件生成的安全作用域书签可用；未修改用户隐私设置、真实共享容器或其他应用。

## 复现与边界

主任务可将 `runConflictChecks()` 加入 HostCheck 入口，并在检查脚本中包含 `ConflictChecks.swift`。本次独立编译宿主依赖包含 `ConflictDialog.swift`、`OpenWithPlanning.swift`、`OpenWithInteraction.swift`，其余依赖与现有 HostCheck 一致。

模拟 `.timedOut` 验证的是宿主收到超时结果后的停止策略和说明，没有实际等待 15 分钟。任务模型检查也不等于实际窗口视觉验收；NSAlert 按钮、复选框、窗口关闭及定时器联动需要真实 UI 通道另行验证。此记录不声明 Finder 共享容器端到端链路已通过。
