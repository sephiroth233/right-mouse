# 完整 Finder 菜单与设置精简验收

日期：2026-09-23。关联 T008、T009、T010、T012–T017，沿用现有菜单、模板、收藏、文件操作和应用打开需求。环境为 Apple Silicon / macOS 27；不代表其他系统、干净机器或互联网下载的 Gatekeeper 验收。

## 目录

- [实现](#实现)
- [自动检查](#自动检查)
- [真实 Finder](#真实-finder)
- [产物](#产物)
- [参考](#参考)

## 实现

- 按[本机 XPC 契约](../contracts/local-xpc.md)通过认证连接读取完整显示快照；书签、模板内容和应用路径留在主应用。
- 每条连接先握手，只读取一次菜单或执行一次请求。主应用校验当前配置、模板/应用/收藏 ID、剪切 token、上下文目标、固定询问策略，并按 requestID 去重。
- 扩展后台同步配置和剪切摘要，菜单构建只读内存；来源确认仅保留于旧 URL 入口。
- 设置移除文件操作台，保留通用、菜单管理、新建文件、常用目录、打开方式、权限与诊断。内部文件引擎和任务结果窗口保留。
- 本机收藏显式保存非安全作用域书签；共享模式使用安全作用域书签。旧配置缺省仍按原类型读取，失败要求重新选择；不回退为路径授权。

## 自动检查

- 核心回归：368 项通过（`.build/full-menu-core-check.log`）。
- 宿主回归：472 项通过（`.build/full-menu-host-check.log`）。新增覆盖模板字节、自定义启动参数、收藏复制/移动、剪切粘贴、重放去重、剪贴板替换、伪造目标和已删除/禁用配置拒绝，以及普通书签往返与损坏拒绝。
- 最终构建 XPC 签名边界：18 项全部通过（`.build/finder-settings-xpc-check.log`、`.build/finder-settings-preview/xpc-checks/results.json`），包括菜单先握手、伪造身份/错误角色/缺失权限拒绝、真实文件创建、重复去重、过期拒绝和服务重启恢复。

## 真实 Finder

隔离数据位于 `.build/full-menu-acceptance`，没有修改用户正常设置。

- 自定义模板“验收模板”从 Finder 创建 `Finder Preview.txt`，45 字节与模板相同，回执 `EEF74B6D-8507-4389-A37A-4E7F29B91D76` completed。
- 自定义“验收 TextEdit”从 Finder 打开 `source.txt`，真实文本编辑窗口显示正确路径和内容，回执 `47098311-CB54-4FC4-8390-3A74C1BE013D` completed。
- 剪切 `cut.txt` 后，在目标目录选择一级菜单“粘贴待移动文件（1 项）”，回执 `B9308F94-5A41-464A-9347-6C56ABD390D5` 和 `7B37C285-8F3F-4579-8345-D692DFE3938C` completed，目标 38 字节一致，源文件移走，粘贴项随后消失。
- 初次收藏复制失败，回执 `8DD8EF26-B6A5-4CB4-AEF6-CB9EAEC36198`；夹具使用其他进程生成的安全作用域书签。普通书签也不能按 `.withSecurityScope` 解析。修复为持久化显式书签类型，按对应选项解析，失败时继续拒绝；后续实测见下文。

最终修复构建在 `.build/full-menu-final-acceptance` 再次实际操作：

- 收藏复制 `source.txt` 成功，41 字节与源文件相同且源保留，回执 `3682E751-5907-48B4-A5C7-283459D39B12` completed。
- 收藏移动 `move.txt` 成功，39 字节相同且源移走，回执 `79074C15-043C-4111-912F-52991D3A7BD4` completed。
- 点击“打开验收目标”后真实 Finder 窗口进入该 target 文件夹，显示上述两个文件，回执 `42D657F4-4C76-461F-93B1-FF110ECE3977` completed。
- 设置页显示收藏有效，不再出现“书签不可用”；侧栏六项且没有文件操作台。

## 产物

最终本机构建目录为 `.build/finder-settings-preview`，公开证书指纹 `c48a8218c126faeae6dc8532573d3896eff85f89`。构建临时私钥和钥匙串已由脚本清理，测试客户端不在应用内。

`dist/RightMouse-0.2.0-local-arm64.dmg` 已通过 `hdiutil verify` 和 SHA-256 校验；SHA-256 为 `9ba05d36274413ce66584c4b9ae1ab117e7327867b825b25309244a83cf3a5ab`。

已从只读挂载的最终 DMG 提取到 `.build/dmg-installed/RightMouse.app`，严格验证嵌套签名，启动时恢复用户正常配置。实际界面显示六个设置入口和“本机连接已就绪”；菜单快照为用户原有的 6 个模板、2 个应用、0 个收藏，没有测试项目。服务程序路径指向该安装副本；只登记一个 Finder 扩展，UUID `D9C123C8-A87E-45A9-B83C-8A9EE0F4FF27`。合法签名客户端对安装副本读取菜单成功。

分步提交：`d0f4b71` 契约、`884de82` 完整菜单与书签类型、`964eb99` 设置入口精简。文档追踪校验通过；该校验不计入产品测试。

## 参考

- [本机 XPC 契约](../contracts/local-xpc.md)
- [集成检查运行方法](../../../tools/RightMouseXPCCheck/README.md)
- [Apple 安全作用域书签创建选项](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withsecurityscope)：此选项用于采用 App Sandbox 的应用；本机非沙盒收藏采用显式区分的普通书签。
