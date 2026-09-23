# 本机 XPC 接入与 DMG 交付验收

日期：2026-09-23。本文保留各阶段历史构建；当前完整菜单版本、DMG 校验值见[完整菜单交付](EV-full-finder-menu-001.md)。关联 T006、T009、T010、T022、NFR-003。本轮完成无账号本机路线的正式操作接入，原 App Group / Developer ID 路线保持独立；完整 V1 跨系统验收任务不据此整体勾选。

## 目录

- [1. 实现与环境](#1-实现与环境)
- [2. 自动检查](#2-自动检查)
- [3. 真实 Finder 与生命周期](#3-真实-finder-与生命周期)
- [4. 产物与边界](#4-产物与边界)
- [5. 侧栏精简与默认询问更新](#5-侧栏精简与默认询问更新)
- [6. 移除最近目标入口](#6-移除最近目标入口)
- [参考](#参考)

## 1. 实现与环境

实际环境为 Apple Silicon、macOS 27.0（26A428），构建部署目标 macOS 14。主应用、Finder 扩展和连接转交服务使用同一次构建的自签名证书和 Hardened Runtime，没有 App Group、Apple Team ID 或 provisioning profile。通过证书指纹与角色 ID 约束 NSXPCConnection / NSXPCListener，主应用连接先交换无敏感信息 nonce 再接收一次有界请求。外部 URL 入口继续确认。

服务只转交主应用 endpoint；主应用仍是配置、任务账本与文件操作唯一执行者。新模板创建、打开应用沿用已有实现，没有在桥接进程再创建一份文件引擎。实现契约见[本机 XPC 契约](../contracts/local-xpc.md)。

分阶段提交：`c7d36f7` 接入认证 XPC 与宿主流程；`705f8d6` 交付本机签名构建、DMG、生命周期界面和集成检查。本文随后归档最终验收结果。

构建 A 的证书指纹为 `c46e50e26744b2320a06f9de6939b990dba5188d`；升级构建 B 为 `f6d3dafa2ea2b28c819fa851c4687279e87868b3`。这两个值只记录公开证书身份，不是密钥。临时钥匙串及私钥已清理。

## 2. 自动检查

| 检查 | 结果和证据范围 |
| --- | --- |
| 核心回归 | 364 项通过；`.build/xpc-core-check.log` |
| 宿主回归 | 424 项通过，其中本轮新增 16 项；`.build/xpc-host-check.log` |
| 本机通道集成 | 16 项全部通过；从 DMG 提取的主应用、服务与沙盒测试客户端；`.build/xpc-distribution-check.log` 和 `.build/local-next/xpc-checks/results.json` |
| 身份拒绝 | 同 ID 的 ad-hoc 伪造客户端、同证书不同角色、缺少查找权限均 exit 3 |
| 宿主入口 | 无需 URL 来源确认即可创建真实 TXT；同 requestID 不生成第二份文件；URL 入口仍需确认 |
| 会话边界 | 未握手拒绝、会话只能一次 perform、不可再次握手重置、超长/过期/畸形/只读请求拒绝 |
| 服务恢复 | `launchctl kickstart -k` 后主应用重新发布 endpoint，随后创建真实文件成功 |
| 旧构建隔离 | 升级后 B 客户端握手成功，A 客户端 exit 3；旧服务名不再存在 |

宿主与核心回归最初在 Codex 文件执行沙盒中受到既有文件访问权限限制；改为正常本机权限运行同一检查二进制后均通过，不将环境失败算产品通过。源码未为绕过检查删减文件访问验证。

集成脚本为 `tools/RightMouseXPCCheck/run-checks.py`；构建时显式 `RIGHTMOUSE_TEST_CLIENTS=1` 才生成这些客户端，它们不包含在发行应用中。运行方法见[检查说明](../../../tools/RightMouseXPCCheck/README.md)。脚本只操作仓库 `.build` 夹具；代码检查不代替下面的系统点击证据。

## 3. 真实 Finder 与生命周期

构建 A 的真实 Finder 扩展进程初始化成功。菜单保留原有一级显示设置：文本文档、完整路径、Markdown、终端、Visual Studio Code，其余仍在 RightMouse 子菜单。

通过原生 UI 自动化实际选择“新建 文本文档”并按 Return，直接生成 `.build/finder-local-acceptance/未命名 3.txt`，没有点击任何来源确认。账本 `70CB100C-A5E2-40A2-B3E7-B9575E1A2849` 为 completed。选择“使用 Visual Studio Code 打开”后，VS Code 的实际窗口为 `source.txt — right-mouse`，路径对应测试文件；账本 `EBE5DB80-6EB3-49C5-9AAA-E543F0B7FB33` 为 completed，原文件保持 37 字节。

退出主应用后，合法测试客户端无法获得旧 endpoint。再次从真实 Finder 新建 TXT，主应用重新启动并直接生成“未命名 4.txt”，账本 `6A9EAA3D-68F8-490E-8C3D-D6100BC45C22` 为 completed。生产代码还为 Finder 唤醒添加 `--finder-wake`，防止启动阶段提前显示设置窗口。

运行随包卸载脚本后，`launchctl print` 显示服务不存在，用户 LaunchAgents 中的对应 plist 已移除。启动构建 B 保留停用偏好，界面显示“本机连接服务已停用”；点击“启用或修复连接”变为已就绪。再从界面点击“停用并移除服务”，服务注册与 plist 同时消失；点击恢复后重新就绪。设置与既有任务保留。

构建 B 的 Finder 登记为 0.2.0，UUID `03BCED4E-1A57-4618-98E1-2E8DADC394C8`，路径为本轮升级应用。DMG 副本启动后，主应用已自动将服务 ProgramArguments 更新到该安装副本的嵌入服务路径，界面仍显示已就绪。

首轮 DMG 安装副本的主应用进程为 82957，Finder 扩展为 82958，均从 `.build/dmg-installed/RightMouse.app` 启动；扩展登记 UUID 为 `E978442E-24E6-4BB3-BD65-CFECA9B75545`。再次从真实一级菜单选择“新建 Markdown”，直接生成“未命名 2.md”，没有来源确认。这补充验证了最终交付副本，而非只在构建目录运行。

## 4. 产物与边界

DMG：`dist/RightMouse-0.2.0-local-arm64.dmg`，并提供同名 `.sha256`。首轮交付 SHA-256 为 `e38dd3ab1c0147fcedddb0e65ab6c78252131cf278d6720c1adcd9bc8494ff3f`。镜像校验通过，只读挂载成功，内部应用与取出后的应用均通过 `codesign --verify --deep --strict`。三个组件证书一致，包内无私钥、P12 或测试客户端。已从镜像取出的 `.build/dmg-installed/RightMouse.app` 启动验收，实际服务路径随之更新。

安装说明在 [本机版安装与升级](../../../docs/local-install.md)。主应用提供启用/修复/停用入口，DMG 还含 Applications 链接、安装说明和仅移除本应用服务的卸载脚本。

用户在本轮验收后确认“暂时没有，先交付本机预览版”。本次交付按该范围验收；跨系统和干净机器矩阵作为后续事项保留。此结果证明当前机器上的本机路线与打包产物，不是 Apple 公证或干净机器矩阵。首次互联网下载、另一用户账户、macOS 14/15/26、Intel 和云盘尚无本轮实测证据。安装说明要求用户核对来源并手动允许运行；必要时仅移除这一个应用的 quarantine，不关闭系统安全机制、不导入根证书、不重新 ad-hoc 签名发行包。当前本机菜单仍限内置功能，自定义模板、应用、常用目录在主应用内使用。

## 5. 侧栏精简与默认询问更新

2026-09-23 按用户要求移除侧栏“任务记录”和“文件操作”，删除全局冲突策略设置页。新建复制、移动、剪切粘贴操作固定使用 `ask`；菜单构建也忽略旧配置中的 `skip` 和 `keepBoth`。文件引擎仍支持用户在本次冲突窗口明确选择跳过、保留两份及应用到本批后续冲突。独立文件任务窗口保留进度、取消与恢复入口；首次演练的“查看任务”改为打开该窗口。

本轮核心 366 项、宿主 434 项通过，日志为 `.build/sidebar-core-check.log`、`.build/sidebar-host-check.log`。新增覆盖旧偏好下的 Finder 菜单策略，以及真实临时文件的复制、移动和剪切粘贴询问、选择跳过后源/目标不变且不创建副本。剪切为非文件变更动作，测试等待持久回执完成，而非等待其不提供的进度卡片。

新版已签名并更新到 `.build/dmg-installed/RightMouse.app`。原生界面读取确认左侧仅有通用、文件操作台、菜单管理、新建文件、常用目录、最近目标、打开方式、权限与诊断，共 8 项；本机连接就绪、扩展已启用。本轮未重复上一轮完整 XPC 生命周期和干净机器测试。

已更新同路径 DMG，`hdiutil verify` 和 SHA-256 校验通过；该轮镜像 SHA-256 为 `a0cd1d250922748f434f40374f4340f4492fb80eaf1bdca82a4e08280d6894a4`。本次构建证书指纹为 `25351add9490eebc563e871e9de5243891f7640b`，此前构建的检查记录保留为历史证据。

## 6. 移除最近目标入口

2026-09-23 继续精简目标选择：移除“最近目标”侧栏页面及复制/移动菜单中的最近目标分组，删除对应 SwiftUI 页面和 Xcode 工程引用。常用目标和系统目录选择器继续使用原有授权与冲突规则。旧记录及书签解析保留兼容，本轮不做数据清理或协议迁移。

核心检查 368 项通过，日志 `.build/compact-core-check.log`；调整了旧菜单断言，验证存在 10 项旧记录时复制/移动都不再出现最近分组，同时验证收藏目标的身份令牌和“选择目录…”动作仍有效。Xcode 工程 plist、SDD 链接/追踪和代码空白检查通过。

本机预览副本已更新并启动，原生界面确认侧栏仅剩 7 项：通用、文件操作台、菜单管理、新建文件、常用目录、打开方式、权限与诊断。界面显示本机连接就绪、扩展已启用。本轮未重复完整宿主/XPC 故障矩阵。

更新后的 `dist/RightMouse-0.2.0-local-arm64.dmg` 通过镜像完整性和 SHA-256 校验，当前 SHA-256 为 `8e68d29700e61aa23edbe282d79dc7b5fbf8f288f8d9558fa1da0f61e0210d55`。构建证书指纹 `4ba4c02cb397cb136e2faf4e68848ffe41bb95fe`，应用通过深度严格签名校验。

## 参考

- [前置 ad-hoc XPC 实验](EV-local-xpc-probe-001.md)
- [本机 XPC 施工契约](../contracts/local-xpc.md)
- [本机版安装说明](../../../docs/local-install.md)
- [Apple 代码签名任务](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
