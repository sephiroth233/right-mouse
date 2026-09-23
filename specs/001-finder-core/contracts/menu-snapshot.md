# Finder 菜单快照契约

菜单快照是宿主私有配置的有界显示投影，文件位于共享根目录的 `Menu/menu.json`。扩展只读取此快照，不读取完整配置、授权书签、模板资源或操作日志。关联需求为 FR-010、NFR-003、NFR-004，实施任务为 T007、T009、T011。

## 目录

- [字段与权限边界](#字段与权限边界)
- [发布与失败处理](#发布与失败处理)
- [版本与迁移](#版本与迁移)
- [参考](#参考)

## 字段与权限边界

[JSON Schema](menu-snapshot.schema.json) 定义 schema 1 的生产者字段白名单。总体最多 8 MiB；动作、收藏、覆盖目录、应用入口、模板各最多 100 项，最近目标最多 10 项。同一集合的 ID 必须唯一。宿主发布前从有效私有配置构造投影，不允许任意字典透传。

| 数据 | 共享字段 | 私有侧保留 |
| --- | --- | --- |
| 菜单 | revision、available、compactMenu、topLevelEntryIDs、conflictPolicy、动作标题与排序 | 登录偏好、新建后定位偏好 |
| 目录 | id、name、path、order | bookmarkData、目录身份、使用时间 |
| 模板 | id、name | resourceName、文件名规则、模板原始内容 |
| 应用入口 | id、name、adapterType、enabled | bundleID、安装路径与应用验证信息 |

目录 path 用于 Finder 覆盖范围、菜单去重与请求定位提示。复制或移动菜单中的 `bookmarkToken` 使用稳定目录 ID，宿主仍须查找私有记录、解析书签并验证对象身份。显示快照不授予文件访问权限。预览和 Finder 都调用同一 `MenuPolicy` 投影入口，避免各自维护业务规则。

## 发布与失败处理

宿主先保存私有配置，再原子发布菜单快照并通知扩展。发布失败时显示明确错误，保留旧快照；宿主重新启动会再次尝试发布。扩展监听菜单目录并周期刷新，读取失败时禁用业务菜单且保留设置入口，禁止回退读取旧版完整配置。

`available: false` 表示宿主处于只读诊断状态，不提供业务菜单。生产者此时发布空动作与引用集合。扩展加载与菜单规划均检查可用性；宿主执行入口也必须独立检查只读状态，不能把菜单隐藏当成权限控制。

JSON Schema 验证生产者输出的字段白名单；Swift 接收器只解码已声明字段并校验版本、容量、数量与 ID，未知字段不会用于授权或执行。未来 schema 快照禁止被旧宿主覆盖；扩展不理解其版本时按不可用处理。

## 版本与迁移

完整配置、模板、操作记录、诊断原件和备份放在宿主 Application Support 的 `RightMouse` 根目录。共享根目录保留 Menu、Inbox、Receipts 和待移动列表摘要。开发降级模式使用独立开发目录下的 Host 子目录，不对 Finder 宣称可用。

旧布局在宿主启动、尚未接受新任务时迁移。新账本锁与旧账本锁同时持有；只在同卷上逐文件原子改名，禁止覆盖，保留文件原始字节和身份。中断后已完成项留在私有目录，剩余项仍在旧侧，重启继续。冲突、链接、不可信目录或跨卷情况保留现场并停止，不发布声称迁移成功的快照。旧锁保留到当前宿主退出，避免旧实例在迁移中继续操作。

topLevelEntryIDs 是 schema 1 的可选新增字段，缺省为空数组。最多 100 个不重复 ID，每个 ID 不超过 160 UTF-8 字节。它可以指向整组动作或叶子菜单项；提升的项目从原位置移除，空父菜单自动移除，保留原动作、目标与禁用规则。父子同时提升时，两者分别位于一级，父菜单不再包含该子项；一级项目按勾选顺序排列。

本机模式不使用共享目录，使用 LocalMenuLayout 的 version、compactMenu、topLevelEntryIDs 展示投影。通过 DistributedNotificationCenter 的 object 字符串发送，userInfo 为空；最大 16 KiB，拒绝未知字段、未知版本、重复 ID 及非内置 ID。通知不携带路径、模板内容、应用路径或权限，也不会执行操作。扩展使用自身 UserDefaults 缓存，主应用启动和设置保存时发布，扩展启动及每 5 秒请求刷新。通知可能丢失或被伪造，因此仅影响内置菜单布局，不能作为操作授权；原有文件操作确认仍生效。菜单回调只使用内存快照。

## 参考

- [数据模型](../data-model.md)
- [菜单快照实现](../../../Packages/RightMouseCore/Sources/RightMouseCore/Menu/MenuConfigurationSnapshot.swift)
- [私有布局迁移](../../../Packages/RightMouseCore/Sources/RightMouseCore/Protocol/PrivateStorageMigration.swift)
- [分层检查](../../../tools/RightMouseCheck/StorageSeparationChecks.swift)
- [Finder 读取入口](../../../Extensions/RightMouseFinder/FinderSync.swift)
