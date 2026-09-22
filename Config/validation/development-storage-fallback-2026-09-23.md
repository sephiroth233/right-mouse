# 开发宿主存储降级验证记录

日期：2026-09-23。此记录针对 ad-hoc 开发包的启动存储选择，区分夹具验证、构建验证与实际桌面验收。

## 原因与修复范围

此前本机 `containerURL(forSecurityApplicationGroupIdentifier:)` 返回了路径，但后续创建 `group.cn.rightmouse.shared/RightMouse` 被系统拒绝，宿主初始化失败。完整拒绝日志与签名边界见 [Finder 加载记录](finder-load-2026-09-22.md)。返回容器 URL 不能证明读写权限。

构建脚本现在向 Info.plist 写入布尔键 `RightMouseAllowDevelopmentStorageFallback`：仅 `--development` 且签名身份为 `-` 的宿主为 `true`；Finder 扩展以及使用真实身份签名的构建均为 `false`，签名后校验也检查该值。

宿主通过 `SharedPaths.resolveAndPrepare()` 创建私有目录，并实际写入、读回和删除一个随机探针。共享目录不可用或准备失败时，仅显式允许的开发宿主使用 Application Support 下独立的 `RightMouse-Development` 目录。开发目录准备失败继续报错，不假装启动成功。正式构建保持原始共享目录错误，不静默降级。

Finder 扩展无论标志如何均不能降级，也不能接受 `RIGHTMOUSE_DATA_DIR`。正式宿主同样拒绝该环境覆盖。开发环境覆盖须为绝对路径。HostController 测试通过显式 `storagePaths` 注入夹具，不依赖生产入口接受环境覆盖。

使用本地开发存储时，界面常驻提示“开发模式 · Finder 菜单暂不可用。可在文件操作台使用本地功能。”侧栏和首次设置步骤也不会把系统扩展登记状态显示成共享通信成功；诊断页保留详细原因。

## 已执行验证

| 验证 | 结果 | 范围 |
| --- | --- | --- |
| 独立 storage harness | 10 个场景通过，退出码 0 | 使用当前 Core 源码单独编译至 `.build/storage-fallback-checks`，临时文件系统夹具与注入失败 |
| 完整 Core 检查 | 129 项通过 | 主任务执行，包含新增 10 场景 |
| 真实 HostController 集成 harness | 59 项通过，退出码 0 | 编译当前宿主逻辑，显式注入临时存储；涵盖创建、复制、移动、恢复、撤销和重试 |
| 开发包完整构建与签名验证 | 通过 | 主任务执行 `scripts/package-app.sh --development`；宿主和扩展验证成功 |
| 产物 Info.plist | 宿主 `true`；扩展 `false` | 读取 `.build/native/RightMouse.app` 及其内嵌扩展的实际 plist，确认值为布尔类型 |

存储场景覆盖：共享目录正常时优先使用共享目录；共享容器缺失；返回 URL 后写入拒绝；正式构建保留原始拒绝；扩展不得降级；允许的显式开发目录；正式构建和扩展拒绝环境覆盖；本地目录也拒绝写入时传播错误；相对路径被拒绝；真实文件系统夹具中容器路径被普通文件占用导致准备失败，降级后该文件原样保留。

Host harness 首次在工具 sandbox 内运行时，系统报告 `sandbox_extension_issue_file ... Operation not permitted`，复制夹具断言失败。随后获准在 sandbox 外运行同一已编译的 `.build/storage-fallback-checks/RightMouseHostCheck`，全部 59 项通过。此执行只使用隔离测试数据，没有伪造用户目录授权、修改 App Group 或隐私设置。

本次开发 ZIP 的 SHA-256（主任务构建记录）：`9b371257f029f9f61f5b09c840181d1111817be7a4ac4687b9c30fd774492052`。

## 尚未证明的部分

本次没有观察到最新开发包正常启动后的可见窗口。CUA `getApp` 仍返回 `Sky Computer Use native pipe closed before response`；可见启动和提示文案的桌面验收仍待恢复 UI 通道后完成。上表的构建、配置检查与夹具通过不能替代这项验收。

本次也没有闭合 Finder 扩展到宿主的真实 App Group 通信。开发 fallback 的目的仅为允许本地宿主功能启动，不赋予扩展读写宿主本地目录的权限。真实 Team、适用的 App Group 授权及签名材料仍须用于后续端到端验收。
