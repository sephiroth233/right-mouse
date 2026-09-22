# Finder 开发扩展加载验证 — 2026-09-22

本记录只证明本机开发构建的登记与进程加载。测试系统为 macOS 27.0（26A428）、Apple Silicon。验证包路径为 `.build/native/RightMouse.app`，是整合前的开发二进制；不得据此声称最新源码、完整右键功能或正式分发通过。

## 签名与登记

`codesign -dv --verbose=4` 显示：

- Identifier：`cn.rightmouse.RightMouse.FinderExtension`
- Signature：`adhoc`
- TeamIdentifier：`not set`
- CDHash：`6d716a13c95f507875ca2a751f065ec3bcf639b4`
- 扩展 entitlement 含 App Sandbox、user-selected read-write 和 `group.cn.rightmouse.shared`。

2026-09-22 23:27（Asia/Shanghai）执行：

```sh
pluginkit -a /Users/lang/workspace/right-mouse/.build/native/RightMouse.app/Contents/PlugIns/RightMouseFinder.appex
pluginkit -m -A -D -vvv -i cn.rightmouse.RightMouse.FinderExtension
```

登记命令返回 0。查询返回一个插件：

```text
+ cn.rightmouse.RightMouse.FinderExtension(0.1.0)
UUID = 954FF365-DB79-451A-AF2F-5BA782D96C4F
SDK = com.apple.FinderSync
Parent Bundle = /Users/lang/workspace/right-mouse/.build/native/RightMouse.app
```

没有执行 `pluginkit -e`，没有启用其他扩展，也没有重启 Finder。`+` 查询结果和下述系统进程共同证明此开发扩展已被系统实际选用。

## 真实进程与系统日志

只读进程查询发现 PID `95597`：

```text
/Users/lang/workspace/right-mouse/.build/native/RightMouse.app/Contents/PlugIns/RightMouseFinder.appex/Contents/MacOS/RightMouseFinder
```

系统日志中与该 PID 对应的证据：

| 本地时间 | 证据 |
| --- | --- |
| 23:27:29.207 | RunningBoard identity 为 `cn.rightmouse.RightMouse.FinderExtension`，宿主关联 Finder PID 657 |
| 23:27:29.208 | PlugInKit：`Bootstrap complete. Ready for handshake from host.` |
| 23:27:29.276 | PlugInKit：`Begin using received` |
| 23:27:29.278 | ExtensionFoundation：`beginning extension request` |
| 23:27:29.280 | Container manager：`container_create_or_lookup_app_group_path_by_app_group_identifier: success` |

因此，在本机系统上，ad-hoc 签名并未阻止扩展进程加载和 App Group 路径查找。不能将此结果推广为其他 macOS 版本或正式分发保证。

## 共享目录与权限边界

App Group 目录存在：

```text
/Users/lang/Library/Group Containers/group.cn.rightmouse.shared
mode=drwx------ uid=501 gid=20
```

验证时其 `RightMouse/` 子目录、`RightMouse/Configuration/` 尚不存在。主代理确认当前宿主进程通过 `RIGHTMOUSE_DATA_DIR=.build/ui-runtime` 使用独立夹具目录，尚未向 App Group 建立配置。扩展 `SharedPaths.resolve()` 只查找路径，未调用宿主的 `prepare()`；配置不存在时其当前代码读取默认配置、监控目录为空。因此现阶段没有真实配置文件可供扩展读取，**不能把容器 lookup 成功等同于共享配置读写或 IPC 成功**。

最近 12 分钟的 RightMouse 自身错误和沙盒拒绝检索：

- 没有找到 `Shared storage unavailable` 或 `Configuration refresh rejected` 自身错误。
- 找到初始化期间 `deny(1) system-info vfs.disk-space`；此记录涉及系统磁盘空间信息，不是共享配置文件读取证据。
- 该检索窗口内没有找到针对共享目录的 file-read/file-write 拒绝记录。这是有限日志观察，不能替代读写测试。

本次没有手工写入共享配置、伪造书签、启动新宿主或修改隐私权限。

## 下一阶段必须完成的证据

1. 稳定源码重新构建后正常启动宿主，不使用 `RIGHTMOUSE_DATA_DIR` 覆盖。
2. 宿主完成真实共享容器 `prepare()`，通过系统目录选择器选择测试夹具目录并保存有效书签和监控配置。
3. 扩展读取同一配置并显示真实 Finder 菜单；通过该菜单提交请求，宿主产生回执和预期夹具结果。
4. 分别验证宿主冷启动、扩展重载、权限撤回及新版覆盖安装。
5. 正式分发仍需实际 Developer ID 签名、合法 App Group 配置、hardened runtime、公证、staple 与 Gatekeeper 检查；本记录没有满足这些发布门禁。

## 2026-09-23 追加诊断：实际写入遭系统拒绝

追加检查获得了比前述 lookup 更强的证据，**当前开发包的 App Group 共享通信尚不可用，G0 未闭合**。前述扩展登记和进程加载仍然成立；容器路径 lookup 成功仅说明取得了路径，不证明后续访问被授权。前一阶段“没有找到共享目录拒绝记录”只对应当时的日志窗口，不适用于下面的后续启动。

### 宿主初始化失败的直接证据

对 2026-09-22 23:35:38（Asia/Shanghai）的正常宿主启动检索，得到：

```text
23:35:38.175 containermanagerd:
[cn.rightmouse.RightMouse] requesting [<private>]: REJECTED.
Requestor's signature does not allow it to access a TCC-protected group container.
Group containers identifiers should be prefixed by requestor's team ID to allow access on this platform.

23:35:38.175 RightMouse[229]:
container_create_or_lookup_app_group_path_by_app_group_identifier: success

23:35:38.225 kernel:
System Policy: RightMouse(229) deny(1) file-write-create
/Users/lang/Library/Group Containers/group.cn.rightmouse.shared/RightMouse
```

同一次启动中，containermanagerd 在 23:35:38.021 与 23:35:38.123 对 `cn.rightmouse.RightMouse.FinderExtension` 也给出相同的签名/受保护容器拒绝。日志同时出现 lookup success 和真实写入拒绝，直接证明它们是不同检查阶段。

宿主代码在 `HostController.init()` 依次调用 `SharedPaths.resolve()` 和 `paths.prepare()`；该文件写入拒绝对应 `prepare()` 建立 `RightMouse/` 数据目录的步骤。代码随后由应用启动错误分支显示错误并退出。当前没有通过 UI 观察到这个错误框，因此“弹框的具体内容”属于代码推断，而非已观察屏幕证据。

### 当前进程与签名状态

2026-09-23 00:00 的只读进程查询：

| 进程 | 启动时间 | 结论 |
| --- | --- | --- |
| RightMouse PID 92981 | 2026-09-22 23:18:11 | 仍在运行的是旧测试宿主；主代理此前确认其使用独立 `RIGHTMOUSE_DATA_DIR` |
| RightMouse PID 229 | 不在当前进程列表 | 23:35 的正常宿主启动已退出 |
| RightMouseFinder PID 230 | 2026-09-22 23:35:37 | 扩展仍运行；运行不等于共享文件访问成功 |

当前磁盘上的宿主包由 `codesign -dv --verbose=2` 确认为 `Signature=adhoc`、`TeamIdentifier=not set`；`Contents/embedded.provisionprofile` 不存在。`~/Library/Group Containers/group.cn.rightmouse.shared/RightMouse` 和 `~/Library/Application Support/RightMouse` 均不存在。没有发现“实际容器位于其他已确认位置”的证据。

CUA 诊断中，重置会话后 `cua.getState()` 能返回应用列表，但两次 `cua.getApp("cn.rightmouse.RightMouse")` 都报 `Sky Computer Use native pipe closed before response`。因此尚不能可靠查看或操作该应用的真实授权提示，也不能把 CUA inventory 成功当作应用 UI 验收通过。本次未用其他自动化技术替代 CUA。

### 结论与可执行下一步

本机实测被拒绝的是 **ad-hoc、无 TeamIdentifier、无 provisioning profile 的当前构建，访问 `group.cn.rightmouse.shared`**。这不意味着所有 App Group 都必须使用 Team ID 前缀，也不意味着只要随意添加一个前缀即可访问。

Apple 官方文档说明：`group.` 标识需要 provisioning profile 授权；macOS 也支持真实签名 Team ID 前缀的另一种格式。`containerURL(forSecurityApplicationGroupIdentifier:)` 在 macOS 上即使组无效也可能返回预期形式的 URL，应验证实际访问能力。[Apple 容器访问配置](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)，[Apple containerURL API](https://developer.apple.com/documentation/foundation/filemanager/containerurl%28forsecurityapplicationgroupidentifier%3A%29)

后续应使用真实开发者 Team，注册并授权本项目的 App Group，让宿主和扩展分别获得匹配的签名与 provisioning profile，再验证共享目录实际创建、配置读取、请求入队和回执。当前环境没有可用签名身份，不能据开发签名登记成功宣布 G0 已通过。不得通过编造 Team ID、修改 TCC 数据库、扩大隐私授权或手工伪造书签来填补这一验收缺口。

与此同时，核心文件操作、协议、模板、菜单规则，以及使用显式夹具目录的宿主功能仍可继续测试。它们的证据应独立记录，不代替真实 Finder 到宿主的共享通信验收。本次只读诊断没有更改源码、共享配置、书签或用户隐私设置。
