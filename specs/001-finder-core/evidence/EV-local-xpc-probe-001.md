# 无 App Group 的本机 XPC 可行性验证

日期：2026-09-23。关联 NFR-003、T009、T010。用户授权尝试以本机 XPC 替代无开发者账号模式的 App Group 通信。本记录为独立实验，不改变当前发布版操作入口。

## 目录

- [1. 验证范围](#1-验证范围)
- [2. 实验设计](#2-实验设计)
- [3. 结果](#3-结果)
- [4. 接入边界](#4-接入边界)
- [参考](#参考)

## 1. 验证范围

验证临时签名的沙盒客户端在无 Team ID、无 App Group 情况下，通过指定名称的 Mach 服务与用户级 XPC 服务通信。仅进行有界随机 nonce 的往返，不创建、修改或打开用户文件，不取消现有主应用确认。

## 2. 实验设计

在 .build/xpc-probe 内生成独立服务和三个客户端，均使用 ad-hoc 签名，最终复核构建启用 Hardened Runtime。合法客户端和伪造客户端使用同一代码签名标识，但二进制内容不同；第三个客户端没有指定服务的 mach-lookup 沙盒例外，但其 CDHash 也加入服务端允许列表，以独立验证沙盒限制。服务通过 setConnectionCodeSigningRequirement 限制客户端的实际 CDHash，并检查有效用户 ID；客户端通过 setCodeSigningRequirement 校验服务 CDHash。测试程序从刚完成签名的本次产物取得预期值，不把 Bundle ID 相同当作可信依据。

服务仅临时 bootstrap 到当前用户的 launchd 会话，plist 留在构建目录，测试 finally 执行 bootout，不安装全局服务或开机任务。检查合法往返、同 ID 不同代码拒绝、缺少查找权限拒绝、错误服务身份拒绝，以及服务首次按需启动和通过 launchctl kickstart -k 替换进程后的重连。

## 3. 结果

本机环境：macOS 27.0（26A428），Apple Silicon。最终构建的签名显示 Signature=adhoc、TeamIdentifier=not set、flags=0x10002(adhoc,runtime)。Finder 探针仅声明 App Sandbox 和指定服务的 mach-lookup 例外，没有 App Group entitlement。

| 验证项 | 结果 |
| --- | --- |
| 合法沙盒客户端向按需启动的服务发送随机 nonce | 通过，回复准确 |
| 相同签名标识、不同 CDHash 的客户端 | 被拒绝，exit 2 |
| 在服务端允许列表中，但没有 mach-lookup 例外的客户端 | 被拒绝，exit 2 |
| 客户端要求不匹配的服务端 CDHash | 收到身份检查失败，exit 2 |
| 服务进程替换后使用新连接 | 通过，回复准确 |
| 真正由 Finder 加载的沙盒扩展 | 通过，日志及实际菜单有证据 |

第一轮通过 kill 发出 SIGTERM 后立即连接出现 8 秒超时，反映进程终止与 launchd 重启之间的竞态；改为使用 kickstart -k 完成进程替换后测试通过。正式接入仍需实现有界重连，不能据此把任意崩溃时序记为已通过。

首次 Finder 探针只执行 pluginkit -a 未得到有效登记；补充登记包含应用后加载成功，复现脚本已包含这一必要步骤。首轮实际 Finder 右键树显示“RightMouse XPC 测试：连接成功，无 App Group”。启用 Hardened Runtime 后再次测试，系统日志为：

```text
2026-09-23 10:11:39.971 FinderProbe[78877] Finder probe started: 8b1cfbe8-9bab-45b1-b063-36bb7a98b498
2026-09-23 10:11:39.999 FinderProbe[78877] Finder authenticated ping passed: true
```

最终 Finder 探针 CDHash：381f953a325943c0726db42f395c9324c46a0df7。测试结果位于 .build/xpc-probe/results.json 与 finder-results.json；前者五项均通过，后者 passed=true。临时服务 bootout、探针停用、注销扩展、注销包含应用均返回 0；后续查询确认测试服务不存在、测试扩展无匹配项，正式 RightMouse 扩展仍为启用状态。

本轮未改变正式应用源码、设置和开发包，现有菜单及操作确认保持原状。

## 4. 接入边界

本机真实 Finder 扩展通信已验证；仍需验证分发包安装位置、SMAppService 后台项目注册、升级后的身份规则变化、卸载和最低支持系统。实验使用的签名散列来自可信测试驱动器，不等于已经解决发行版的身份引导；正式代码不能允许外部请求自行提供用于授权的散列。客户端的签名要求检查接收消息；本次错误服务要求测试中服务可能已经收到无敏感内容的 ping，所以必须先完成身份握手，再发送文件路径或执行请求。正式接入还需完成主界面与后台服务的存储归属、文件操作回执及去重。

## 参考

- [此前 App Group 拒绝记录](../../../Config/validation/finder-load-2026-09-22.md)
- [当前本机确认模式](EV-local-finder-001.md)
- [XPC 探针代码](../../../tools/RightMouseXPCProbe/Probe.swift)
- [Apple：XPC 连接签名要求](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Apple：指定 Mach 服务的沙盒例外](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
