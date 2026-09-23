# 系统服务兼容入口

状态：施工中。前置证据：[iCloud 菜单排查](../../docs/icloud-menu-investigation.md)。

## 目标与范围

在 Finder Sync 菜单不可用的位置，通过 macOS Services 提供五个固定入口：新建 TXT、新建 Markdown、复制完整路径、在终端中打开、使用 VS Code 打开。系统决定菜单位置，不能承诺显示于右键第一层。

服务不接管或替换已有 Finder 扩展。服务清单由系统设置管理，不跟随应用内一级菜单/子菜单布局；实际执行仍检查模板、操作和打开方式是否启用。服务只能处理系统交来的本地文件 URL，不能以文本解析命令或远程 URL。云盘在 Finder 中交来的 file URL 属于支持输入。

本阶段不提供剪切、移动、复制到等云盘传输功能，不宣称通过云端占位文件、离线下载和跨设备同步验收。

## 行为要求

- 新建服务只对文件夹提供，必须且只能接收一个目录；空白处如系统传来当前目录，可在此创建。无法取得目录时报错，不猜测上次位置，不弹出选目录窗口绕过错误。
- 复制路径接受 1–128 项；终端接受一个文件或文件夹；VS Code 沿用现有多选目录规划。
- 未知服务 ID、非文件 URL、远程主机 file URL、空输入、过量输入应拒绝；限制 URL 总体积，避免无界请求。
- 复用宿主现有模板创建、复制路径和打开方式流程，不执行拼接 shell，不允许服务入参指定应用或脚本。
- 新建采用现有同名自动编号行为；正常完成不显示任务窗口、不保留操作历史。实际错误仍可见。
- 服务冷启动不得显示设置窗口或 Dock。手动打开应用仍显示设置；菜单栏仍遵循原开关。
- 标记可能扩大沙盒能力的服务为 `NSRestricted`，保留系统对沙盒调用者的保护；不自制 URL 来源确认弹窗。

## 实施与验收

1. 已用独立只读服务确认：iCloud Documents 空白处可显示服务、可冷启动应用、传来当前目录 file URL；不读取文件内容。
2. 实现独立服务输入规划和 provider，通过配置白名单生成现有宿主操作。
3. 声明五个 NSServices，接入宿主服务注册与启动策略，更新构建工程。
4. 单测异常输入、目标目录、配置停用、冷启动；真实宿主在本地夹具验证创建及复制路径，不改动个人云盘内容。
5. 独立预览验证 iCloud 服务实际调用、冷启动无窗口与本地文件创建；退出、注销测试应用并恢复现场。保留已安装发行版，不推送/发布。

自动化测试不能替代真实 Finder Services 分发；云盘写入和同步若未验收必须明确标注。完整实现后更新用户安装说明及验证证据。

参考：[Apple Services 属性](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html)、[提供系统服务](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html)。
