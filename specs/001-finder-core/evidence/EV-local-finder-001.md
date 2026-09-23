# 无开发者账号的本机 Finder 模式

日期：2026-09-23。关联 T020、T021、AC-025。本文记录本机验收路线；正式签名与完整 Finder 验收仍独立追踪。

## 目录

- [1. 问题与范围](#1-问题与范围)
- [2. 实现契约](#2-实现契约)
- [3. 验证记录](#3-验证记录)
- [4. 构建与交付](#4-构建与交付)
- [参考](#参考)

## 1. 问题与范围

本机无有效代码签名身份。系统已启用扩展，但拒绝 ad-hoc 构建访问 App Group。旧版只在共享菜单快照读取成功后登记监控目录，失败后目录为空，Finder 不会生成右键入口。用户明确选择不配置开发者账号、优先本机可用。

新增独立本机模式，不改变正式签名版本的共享队列协议。扩展仍使用 App Sandbox。主应用直接使用已有开发数据目录，扩展不读取主应用私有数据、不访问共享容器。

## 2. 实现契约

仅 ad-hoc development 构建在宿主和扩展 Info.plist 同时写入 RightMouseLocalFinderMode=true，并去除双方 App Group entitlement。本机扩展使用内置菜单、普通本地目录与挂载卷的监控范围；路径仅决定菜单出现范围，不授予文件访问权。云盘提供方与其他扩展竞争的覆盖范围需真机验证。

复制路径、文件名等纯文本操作可由用户点击的扩展菜单直接写入剪贴板。其他内置动作使用独立 local-action URL 传递有界、严格校验的请求。URL 上限 48 KiB，最多 128 个选中项，采用规范 base64url 与 WireCodec JSON 编码。URL 不能证明来源，宿主必须逐次展示动作与完整文件列表，默认取消；用户确认后才提交现有幂等账本和文件引擎。取消不创建任务、不触碰文件。未知动作、书签令牌、超限、过期、额外字段均拒绝。正式构建拒绝此入口。

本机菜单不读取主应用自定义配置、常用目录或待移动令牌。首版提供内置新建、文本复制、复制到/移动到与打开方式；剪切和粘贴会话继续在应用内使用，避免静态菜单生成无效令牌。界面须明确此范围，不能把“已启用扩展”表述为功能已完成验收。

## 3. 验证记录

本机系统为 macOS 27 arm64。核心夹具 341 项、宿主检查 408 项通过，其中新增本机协议 23 项、宿主入口 19 项。覆盖禁用入口、过期/超限/非规范编码、外来书签、取消零副作用、确认后真实创建、重复 ID 不重放、模态重入拒绝、只读拒绝与特殊字符路径展示。首次核心运行在受限环境中遇到文件协调失败；允许系统文件协调服务后，同一已构建测试程序通过，不将受限运行记为通过。

真机 Finder 在 `.build/finder-local-acceptance` 中显示 RightMouse 子菜单及全部本机入口。测试点击新建文本文档，扩展沙盒曾在 `Bundle(url: host)?.bundleIdentifier` 处无法读取宿主 Info.plist，被误判为身份不符。现从扩展自身的 Contents/PlugIns 嵌套位置推导宿主路径，由 Launch Services 打开；不扩张沙盒读写权限。菜单上下文另保存在扩展内部，以整数 tag 跨 Finder 进程传递，120 秒过期、限定容量，避免依赖自定义 representedObject 的跨进程保存。

2026-09-23 09:05:19（Asia/Shanghai）从真实菜单发起请求 `7CF092BA-020F-475E-821A-DC63AA5B5844`，09:05:23 回执 completed，产生未命名.txt。09:08:15 再次由菜单发起请求 `16B7A9DD-909B-4078-B3AF-602B33C0919B`；日志显示宿主新进程 69911 在 09:08:16 接收 URL，09:08:22 回执 completed，产生未命名 2.txt。第二次过程中主应用此前已退出，确认冷启动后可以进入处理。新文件均为 0 字节 TXT，原 source.txt 保持 37 字节；同名文件未覆盖。

原生 UI 工具实际读取到“确认这次文件操作”对话框，展示目标目录、选中 source.txt 和“确认并继续 / 取消”。界面随后被用户操作改变，工具的取消点击未能完成，因此不声称真机取消已验收；取消零副作用由 19 项新增宿主检查覆盖。实际文件与 ledger 已通过只读检查核对。旧版在已有主窗口时，原生工具曾只返回后台设置窗口而未取到确认窗口，不能据此把 URL 接收断言为失败。当前另外明确安装 kAEGetURL 接收器并在初始化完成前缓存最多 8 个 URL，复用同一校验入口；日志不记录完整 payload 或文件路径。

本次证明普通本地目录的菜单、新建、同名保留与宿主冷启动链路。真实 Finder 的四类上下文、批量复制/移动、跨多个卷、云盘提供方、权限撤回、最低 macOS 14 与完整可访问性仍未全量验收。正式 App Group、Developer ID 签名、公证仍未完成，不将对应完整 AC/T 状态勾选。

## 4. 构建与交付

最终执行 scripts/package-app.sh --development 成功，宿主、扩展、签名结构与构建模式验证均通过。扩展仍包含 app-sandbox=true，双方本机签名不含 application-groups。宿主遵循原有非沙盒直接分发设计；确认并不授予 TCC 权限，受系统限制的路径仍正常报错或需要系统授权，未关闭任何系统保护。

开发包：dist/RightMouse-0.1.0-development.zip；SHA-256：`1d4f420770341042c4f08a5a3c8d2d075681c6118bda1f96cd15c83e14876ca8`。最后一次修改仅改善确认路径的斜线显示，特殊字符仍转义；408 项宿主回归再次通过。最终包已重新登记并打开，pluginkit 返回启用状态与准确的 .build/native/RightMouse.app/Contents/PlugIns/RightMouseFinder.appex 路径，注册 UUID 为 0B7A94F9-4EC8-4F8D-B3AF-514B19F4A6CB。

SDD 校验通过：30 份 Markdown、20 项需求、23 项任务、31 项验收用例、3 个 schema 与 22 个文档探针。文档检查不计作产品测试。正式签名、公证及其余完整验收继续保持未完成。

## 参考

- [Apple：Finder Sync](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
- [Apple：创建扩展与 ad-hoc 测试](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)
- [验收清单](../checklists/acceptance.md)
- [签名与构建说明](../../../Config/README.md)
