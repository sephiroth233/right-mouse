# 本机 XPC 探针

独立的可行性实验，验证没有 Apple Developer 团队、没有 App Group 的临时签名沙盒进程能否通过指定 Mach 服务进行 XPC 消息往返。所有测试仅传递随机 nonce，不操作文件或执行外部命令。它不是正式的文件操作服务，也不是安装器。

## 目录

- [1. 构建](#1-构建)
- [2. 验证](#2-验证)
- [3. 清理与限制](#3-清理与限制)
- [参考](#参考)

## 1. 构建

在 macOS 图形登录会话中，从仓库根目录执行。需要 Apple Command Line Tools，不需要签名证书；使用 ad-hoc 签名并启用 Hardened Runtime。

```sh
python3 tools/RightMouseXPCProbe/build-probe.py
python3 tools/RightMouseXPCProbe/build-finder-probe.py
```

产物在 `.build/xpc-probe`。构建程序记录本次客户端与服务端的 CDHash，由可信测试驱动器分别配置 XPC 对端要求。合法与伪造客户端使用相同标识但不同代码，避免把 Bundle ID 相同当作来源证明。

## 2. 验证

以下测试会临时注册当前用户的 launchd 服务；Finder 测试还会短暂登记独立的 `cn.rightmouse.XPCProbe.Finder` 扩展。不要并发执行两个测试，不要用于系统登录窗口或 root 会话。

```sh
python3 tools/RightMouseXPCProbe/run-probe.py
python3 tools/RightMouseXPCProbe/run-finder-probe.py
```

第一项检查合法连接、相同标识的其他代码、缺少沙盒查找权限、错误服务身份以及服务替换后重连。缺少查找权限的客户端也在服务端 CDHash 允许列表中，确保这一反例单独检查沙盒边界。

第二项等待真实 Finder 加载探针。在 Finder 打开 `.build/finder-local-acceptance` 后，右键菜单可显示“RightMouse XPC 测试：连接成功，无 App Group”。自动检查带有本次随机运行 ID 的系统日志。最多等待 150 秒，成功后额外保留 25 秒用于查看，然后自动清理。结果写入 `results.json` 和 `finder-results.json`。

## 3. 清理与限制

两个测试均在 finally 中执行 launchctl bootout；Finder 测试另行停用、注销扩展和包含应用。不会安装到 Library/LaunchAgents，也不会修改正式 RightMouse 的设置或扩展。

若进程被强制终止而未能执行 finally，可从 results 文件和 `launchctl print gui/$(id -u)/cn.rightmouse.xpc-probe.$(id -u)` 检查现场，再只卸载本探针服务。正常结束时 cleanup 的所有返回码应为 0。

签名要求限制接收到的 XPC 消息，不能把发送首条消息当作完成对端认证。正式接入必须先用无敏感信息的握手确认服务身份，再发送文件路径和操作。此实验尚未实现发行版的身份引导、升级规则、后台项目注册引导和卸载，不能直接去掉正式应用的请求确认。

## 参考

- [完整实验记录](../../specs/001-finder-core/evidence/EV-local-xpc-probe-001.md)
- [Apple：XPC 对端代码签名要求](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
