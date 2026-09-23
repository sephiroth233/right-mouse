# 本机发行版 XPC 施工契约

无 Apple Developer 账号的本机发行路线。日期：2026-09-23；关联 T006、T009、T010、T022、NFR-003。此契约补充现有共享容器路线，目标为真正 Finder 操作免逐次来源确认、可安装升级卸载的 DMG。

## 目录

- [1. 身份与范围](#1-身份与范围)
- [2. 通信与数据所有权](#2-通信与数据所有权)
- [3. 生命周期和失败](#3-生命周期和失败)
- [4. 交付与验收](#4-交付与验收)
- [参考](#参考)

## 1. 身份与范围

采用每次构建生成的自签名代码签名证书，不安装信任根、不获取 Team ID、不申请 App Group。证书指纹写入各组件签名保护的 Info.plist。连接要求同时匹配确切 certificate leaf 和角色 identifier，并检查同一有效用户。构建私钥仅保存在临时构建目录/钥匙串，完成或失败后清理，不包含于发行产物。

证书用于组件相互认证，不提供 Gatekeeper 信任或公证。用户仍须首次允许未公证应用运行及启用 Finder 扩展。攻击者能修改用户认可并运行的整个程序不在此认证保证内；仅使用同 Bundle ID 或重新签名的外部客户端必须被拒绝。不能仅信任代码自行报告的身份。

## 2. 通信与数据所有权

```text
Finder 扩展 → 连接转交服务（只返回主应用 endpoint）
Finder 扩展 → 主应用匿名 XPC listener → 现有 HostController → 任务账本与文件引擎
主应用 → 连接转交服务的独立注册入口 → 发布 endpoint
```

转交服务不收文件路径和命令。注册入口只接受本次构建的主应用；查询入口只接受本次构建的 Finder 扩展。两个入口使用独立 Mach service，扩展仅获得查询入口的精确 mach-lookup 沙盒例外。

Finder 获取 endpoint 后仍要验证主应用身份，并先交换无敏感信息的随机 UUID，校验协议版本和完整回显，再发送有界请求。主应用 listener 校验扩展签名，按连接要求先握手、后接受一次请求。保留 LocalFinderRequest 的白名单、大小、时效、配置可用性和不可注入书签限制；账本继续按 requestID 去重。URL 入口没有这份权限，仍需人工确认，禁止自动失败降级为无确认 URL。

## 3. 生命周期和失败

用户级 launch agent 按需启动转交服务，无 root、无系统守护进程。主应用首次启用时安装，设置中支持修复和停用。退出主应用后 endpoint 随连接失效被清理；Finder 下一次操作通过精确宿主路径唤醒主应用，等待新 endpoint，界面不抢焦点。主应用持续检测转交连接，服务重启后重新注册。

构建证书变化时 Mach service 名随之变化，旧扩展不能悄悄连接新主应用。升级必须替换整个应用、重载扩展、更新 launch agent；新主应用检测旧注册路径并重新安装。服务停用必须清理 launchd 注册与自身 plist，保留用户设置和任务记录。请求发送前允许有界重连；发送后超时不能盲目重试，以免重复副作用，提示查看任务记录。

## 4. 交付与验收

施工顺序：协议和 SDD → 主应用与扩展接入 → 构建与生命周期 → 真实 Finder / 失败检查 → DMG 和文档。分阶段 Git 提交，不以本契约代替通过证据。

必须检查：真实新建文件与打开应用不显示来源确认；外部 URL 仍需确认；相同 ID 不同证书被拒绝；未握手和重复 perform 被拒绝；过期/过大/无效请求无副作用；重复 requestID 不重复执行；宿主冷启动、服务重启、停用/恢复、升级身份轮换；DMG 挂载与产物签名验证；现有核心和宿主回归。最低编译目标 macOS 14；本机实测 macOS 27，其他系统及互联网下载后的 Gatekeeper 行为需要独立测试，不用本机测试替代。

## 参考

- [前置可行性实验](../evidence/EV-local-xpc-probe-001.md)
- [Apple 代码签名任务](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
- [Apple 签名 requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Apple XPC listener 身份限制](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))
