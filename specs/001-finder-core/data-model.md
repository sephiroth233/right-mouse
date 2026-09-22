# V1 数据模型与操作状态机

定义数据所有权、版本、持久化顺序和崩溃恢复判断，使文件操作可以被追踪和核对。

版本：0.1.0；模型 schemaVersion：1；读者：核心执行器、存储和界面开发者。字段为语义契约，Swift 具体类型在实现中映射，不要求按本文名称创建数据库表。

## 目录

- [1. 模型与所有权](#1-模型与所有权)
- [2. 状态机机制与不变量](#2-状态机机制与不变量)
- [3. 持久化与恢复](#3-持久化与恢复)
- [4. 配置升级和保留策略](#4-配置升级和保留策略)
- [参考](#参考)

## 1. 模型与所有权

| 模型 | 核心字段 | 唯一写入者与约束 |
| --- | --- | --- |
| AppConfiguration | schemaVersion、revision、actions、favorites、recentDestinations、integrations、watchedLocations | 宿主私有；revision 单调递增；不直接共享给扩展 |
| MenuConfigurationSnapshot | schemaVersion、revision、available、菜单显示信息与引用 ID | 宿主发布、扩展只读；8 MiB 上限；无书签、模板资源或操作历史 |
| RecentDestination | id、name、path、bookmarkData、directoryIdentity、lastUsedAt | 最多 10 项，最近使用者移到首位；path 只作展示提示，执行时解析书签并核对设备、inode、类型 |
| MenuAction | id、commandType、enabled、order、groupID、contexts | 宿主；稳定 ID 不随展示名变化；数量 <= 100 |
| ActionContext | invocationID、entryPoint、container、selection | 扩展生成不可变快照；selection <= 1024；不证明访问权 |
| FileReference | refID、fileURL、kindHint、bookmarkToken? | 来源进程创建；URL 为定位提示；宿主验证实际对象类型 |
| AccessGrant | grantID、bookmarkData、scope、ownerIdentity、stale、lastResolvedAt | 实际持有授权的进程；原始书签不进命令 URL/日志 |
| Template | templateID、displayName、resourceName、extension、defaultStem、textVariables、digest | 宿主；资源路径限应用模板目录；禁止 `..` 逃逸 |
| FavoriteLocation | favoriteID、grantID?、fileReference、displayName、order、availability | 宿主；删除收藏不删除目录；不可用需用户修复 |
| AppIntegration | integrationID、bundleID、applicationRef、adapterType、capabilities | 宿主；能力为 file/folder/workingDirectory；安装位置变更需复验 |
| PendingMove | token、references、createdAt、expiresAt、pasteboardMarker | 宿主会话内；24 小时失效；退出/崩溃后不恢复为活动剪切列表 |
| OperationRecord | operationID=requestID、requestDigest、schemaVersion、revision、state、createdAt、items、error、retryOf? | 宿主单写；变更执行前先持久 accepted |
| OperationItem | itemID、sourceRef、destinationRef、sourceIdentity、destinationIdentity、phase、intent、result、error、cleanupPending | 宿主；逐项存储阶段，不能只记录整批百分比 |
| FileIdentity | volumeID、resourceID、kind、size、modificationTime、changeTime?、digest?、metadataDigest? | 执行器实际读取；不信任调用方上报值；不同文件系统可缺部分字段 |

`bookmarkToken` 使用共享菜单快照中的稳定目录 ID，由宿主在私有配置中找到对应授权，不是权限凭据。宿主检查记录归属、过期、协议和可解析性；不能将 token 当路径拼接。app-scoped bookmark 的签名/进程可用性由访问适配器验证，失败转为重新授权。[Apple 书签访问规则](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

`kindHint` 只用于菜单初步展示；执行前用真实文件信息复核。路径相同而资源身份不同，按被替换处理；身份不稳定的目标卷，禁止凭路径删除恢复现场。摘要用于校验内容，不用于证明用户授权。

## 2. 状态机机制与不变量

### 2.1 请求/整批操作状态

```text
received -> accepted -> planning -> running -> completed
                          |           |     -> partial
                          |           |     -> failed
                          v           v
                    waitingForUser  cancelling -> cancelled / partial
                          |
                     planning（重新校验）

任何非终态 + 崩溃/证据不完整 -> needsReview
needsReview -> 用户选择 + 重新校验 -> planning / 已核对的终态
received -> rejected（非法/过期，不进入执行器）
```

`received` 仅为接收阶段；accepted 后 expiry 不再中止正在运行的操作。UI 等待 10 秒没有回执只提示“正在连接或等待”，不能创建新 requestID 自动重试。`waitingForUser` 等待上限建议 15 分钟，到期停止未开始项目并报告已完成项，不回滚已完成文件。

冲突对话框展示前先持久保存 `waitingForUser`，选择后保存 `running`，随后引擎重新核对来源与目标目录身份。任务级“对本批后续冲突使用同一选择”仅覆盖此请求的后续冲突，不修改全局偏好；不持久重放用户选择。等待状态的写入失败会停止后续操作并进入核对。关闭窗口、取消或 15 分钟到期均取消剩余项目，已完成项保持原结果。重启后不存在可继续的旧对话框，等待任务进入 `needsReview`。

最近目标是 schema 1 的可选新增字段：旧配置未包含该字段时按空数组读取，保留原偏好。配置保存前检查编码总量不超过读取器的 8 MiB 上限。最近目标或收藏菜单将记录 ID 写入既有 `FileReference.bookmarkToken`；宿主必须找到对应记录并解析书签，未知或已移除 token 明确拒绝，不按捕获的路径文字降级。手动选择、成功使用会更新历史；移除和清空只影响记录，不删目录。失效项只有经新的系统目录选择才更新授权和身份。

整批聚合规则：全部项目成功为 completed；全部跳过为 completed 并明确零变更；有成功且有失败/取消/跳过为 partial；无成功且用户取消为 cancelled；无成功且错误为 failed；任一项需要核对则优先 needsReview。全跳过不能在 UI 写成“全部移动成功”。

### 2.2 跨卷单项目阶段

```text
planned
  -> staging -> verified -> committing -> targetCommitted
  -> sourceCleanupPending -> sourceRemoved -> done

targetCommitted -> sourceRetained（无法证明可安全删除）
任意阶段 -> failed / cancelled / needsReview
```

上述箭头为同一主链：`planned → staging → verified → committing → targetCommitted → sourceCleanupPending → sourceRemoved → done`。`intent` 记录下一步副作用，例如 commitTarget、removeSource。执行前保存意图，执行后保存观察到的结果，便于识别“文件操作成功但日志尚未写入”的窗口。

复制操作在 targetCommitted 后直接 done，不进入源清理。源保留表示目标可用但移动未完整结束，整批至少 partial；磁盘满发生在暂存阶段不得改变源。取消发生在 targetCommitted 后、源清理前时保留两份并报告 sourceRetained。

### 2.3 剪切列表生命周期

新剪切生成新 token，向剪贴板写私有标记；粘贴要求标记、宿主活动 token、时效均匹配。剪贴板被改写、超过 24 小时或宿主重新启动，则旧列表失效；新剪切覆盖旧列表。成功项目移出列表，失败/跳过项留存并刷新标记；在宿主崩溃后只能进入操作恢复，不通过过期剪贴板自动接续。

## 3. 持久化与恢复

宿主在私有 `Operations/Followups/<requestID>.json` 保存传输的实际目标、逐项结果、重新访问所需的安全书签、撤销开始/完成集合和重试任务关联。该记录不修改原始命令回执。每个撤销项目先验证来源/目标授权及原引擎日志，再持久保存开始意图；引擎完成后保存完成标记。`undoStarted - undoCompleted` 非空表示存在未确认副作用，重启后进入核对，禁止自动重放。

撤销与普通文件变更共用宿主串行队列。重试仅选择明确失败项，沿用已记录的目标，生成新的请求 ID；新请求持久接受后才关联父任务。如果关联写入失败，宿主在该子任务获得执行机会之前取消排队工作。Finder 发起任务的重试保持目录授权约束，不伪装为一次新的系统目录选择。重试入队及执行时复核目标目录身份和失败来源的原引擎身份（设备、inode、类型、大小、mtime）；替换对象或缺少原身份均要求重新选择。恢复时交叉检查后续记录与原回执的项目 ID、状态、目标，并在撤销前核对引擎日志的身份和摘要凭据。

App Group 中保存 Menu 显示快照、Inbox、Receipts 和待移动摘要；宿主私有 Application Support 中保存完整 Configuration、Templates、Operations、Diagnostics 与 Backups。共享存储仅暴露扩展需要的最小信息，见[菜单快照契约](contracts/menu-snapshot.md)。宿主是配置、快照、回执与操作日志的唯一写入者；扩展可以多进程写入独立 requestID 文件。旧布局的私有数据在同时持有新旧账本锁时逐文件原子迁移；同名冲突、跨卷或不可信对象停止迁移并保留原件。

每次日志更新采用同目录临时文件 → 完整编码和校验 → 同步 → 原子替换；具体 fsync/目录同步支持在目标卷验证。应用进程崩溃恢复是 V1 必测范围；突然断电和硬件故障不宣称绝对持久性。日志写入失败禁止启动下一步破坏性操作。

| 恢复时证据 | 处理 | 禁止行为 |
| --- | --- | --- |
| 暂存副本存在、未提交 | 核对归属与授权，符合条件时展示显式清理；源保留 | 将暂存视作最终完整目标 |
| 日志为 committing，目标已存在且身份/摘要匹配 | 记录“目标可能已提交”，复核后接受该结果，源保留待确认 | 再创建同一目标或立即删除源 |
| 目标提交成功，源也存在 | 展示两份位置和核对结果 | 自动按旧清单递归删除源 |
| 日志为 removeSource 意图，源缺失、目标匹配 | 可以归并为源清理已发生，记录恢复推断及证据 | 在别处寻找同名源继续删 |
| 日志显示成功但目标/源身份不匹配 | needsReview，保留现场 | 根据旧路径重放操作 |
| 日志损坏/版本未知 | 备份损坏文件，显示诊断并禁用该任务恢复写入 | 清空日志后重新执行 |

暂存清理仅限能验证 taskID 和归属的路径；启动时不得按一个通配符删除所有隐藏文件。仍有 needsReview 的任务不做自动清理。支持用户在核对后显式清理孤立暂存，并显示文件系统分配空间估算。创建时持久保存暂存及父目录身份；清理凭据绑定检查时日志摘要。清理依次保存 requested、同父目录禁止覆盖改名、按目录描述符删除、保存 completed，并与普通文件变更共用宿主队列。旧记录缺少归属身份时只展示和保留。目录已删除但完成记录写入失败时仍返回需要核对，不改写原请求结果。

## 4. 配置升级和保留策略

配置与日志独立版本化，先备份再迁移，新 schema 校验成功后才替换。应用旧版本遇到更高 schema 进入只读诊断；不以默认配置覆盖未来版本数据。模板导入先复制并校验资源，再提交配置引用；失败临时资源可清理，旧资源保持有效。

终态请求回执和去重索引默认保留 30 天；入队 TTL 为 120 秒，因此过期索引清理后旧请求仍会被时效规则拒绝。未终结任务与 needsReview 记录不按时间自动删除。调试日志滚动保留 7 天/最多 10 MiB，两者先达者生效；此数值为项目初值，T021 可据测量调整并同步文档。

## 参考

- [需求规格](spec.md)
- [技术方案](plan.md)
- [命令协议](contracts/command-protocol.md)
- [Apple 文件协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
