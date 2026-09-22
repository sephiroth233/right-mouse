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
