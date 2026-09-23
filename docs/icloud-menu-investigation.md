# iCloud 右键菜单诊断

日期：2026-09-23。关联 SDD：`specs/001-finder-core/research.md` 的 EXP-04。

## 问题与验收范围

用户报告 0.2.1 在普通目录可用，iCloud 云盘完全没有 RightMouse 菜单。
本轮只定位菜单入口，不执行云盘文件操作，也不将诊断扩展作为产品发布。

## 实验设计

1. 核对发行版版本、扩展启用状态；在 Finder 中比较普通目录、iCloud 根目录与子目录。
2. 用独立 bundle ID 的最小 Finder Sync 扩展，显式注册一个本地夹具目录、iCloud Drive 真实根目录及已有的 Documents 子目录。
3. 诊断菜单只有禁用项；扩展只记录初始化、目录观察和菜单回调的分类，不记录文件名称或内容，不接入 RightMouse XPC、配置和文件操作引擎。
4. 临时停用产品扩展以避免自身竞争；完成后注销诊断扩展并恢复原启用状态。安装中的发行版二进制和配置不替换。
5. 必须先证明相同探针在本地夹具工作，才能把云盘缺少回调计为有意义的失败。仅日志缺失不能单独证明系统限制。

## 初始事实

- `/Applications/RightMouse.app` 版本 0.2.1，`pluginkit` 显示产品扩展 `+`（启用）。
- 普通项目目录中的文件右键菜单包含新建文件、指定应用打开、复制路径、剪切、复制到、移动到和 RightMouse 设置。
- 使用“前往文件夹”进入 `~/Library/Mobile Documents/com~apple~CloudDocs`，对 Documents 文件夹右键，没有任何 RightMouse 菜单；系统 Services 菜单仍可见。
- 产品扩展监控 `/`、`/Users`、Data 卷及挂载卷，没有显式排除 iCloud。尚不能据此断言目录注册一定覆盖云盘。

## 结果

环境：macOS 27.0（26A428），arm64；产品版本 0.2.1。诊断扩展使用独立自签名证书及 `cn.rightmouse.ScopeProbe.Finder` 标识，沙盒权限只有 `com.apple.security.app-sandbox`，无 App Group、文件写入权限、XPC 或业务配置。

| 扩展 | 位置及操作 | 实际结果 |
| --- | --- | --- |
| 已安装 RightMouse | 普通项目目录，文件右键 | 正常显示产品菜单 |
| 已安装 RightMouse | iCloud 根目录，文件夹右键 | 不显示产品菜单 |
| 已安装 RightMouse | iCloud Documents 子目录，空白处右键 | 不显示产品菜单 |
| 最小探针，产品扩展临时停用 | 本地夹具，文件右键 | 显示「RightMouse 目录诊断（只读）」禁用项 |
| 同一探针 | 显式注册 iCloud 根目录，文件夹右键 | 不显示诊断菜单 |
| 同一探针 | 显式注册 iCloud Documents 子目录，空白处右键 | 不显示诊断菜单 |

本机日志的对应条目（系统当地时间）：

```text
14:34:20 probe initialized; exact roots=3
14:34:30 begin observing: local
14:34:34 menu callback: local kind=0
14:37:21 begin observing: local
14:37:28 menu callback: local kind=0
```

后续云盘交互没有出现 cloud-root / cloud-child 目录观察或菜单回调日志。结合原生菜单控件树及本地阳性对照，可排除“探针没有成功加载”和“缺少显式注册 iCloud 路径”。问题发生在菜单入口，尚未进入产品的文件操作或 XPC 代码。

编译源、构建脚本和回调日志位于本地忽略目录 `.build/icloud-probe/`，未将个人云盘文件名、内容或临时签名私钥纳入仓库。

第二次本地回调发生在云盘测试之后，同一进程仍然显示诊断菜单，排除探针中途崩溃。

## 清理与剩余限制

- 已停用、终止、注销诊断扩展及宿主的 Launch Services 注册，删除本次生成的测试 app；保留本地探针源码和日志。
- 已恢复产品扩展 `+` 状态，并通过 Finder 实际菜单确认新建文件、剪切、复制到、移动到、设置等入口恢复。
- 已安装发行版二进制、产品配置以及云盘文件内容均未修改。
- 微信输入法 Finder 扩展已完成停用对照并恢复原启用状态，详情见下节。WPS Finder 扩展保持原默认注册状态，未更改。
- 本结果不外推至其他 macOS 版本、OneDrive、Dropbox 或所有 iCloud 子目录。没有执行云端文件下载、创建、复制、移动的验收。

当前判断：在本机环境中，显式监控路径不能让 Finder Sync 菜单覆盖所测试的 iCloud 位置，且问题早于 RightMouse 的业务代码。停用微信输入法 Finder 扩展没有改变结果，可以排除“停用该扩展即可恢复云盘菜单”的假设。综合证据支持当前 Finder Sync 方案在这些云盘位置存在兼容限制；未做其他 macOS、干净系统或所有第三方软件的全面组合验证。后续若产品要支持云盘，应先验证 Services 入口，而不是将未经证实的路径补丁发布为修复。

仅文档变更；`git diff --check` 及 SDD 文档校验通过。未重新运行与本次诊断无关的文件操作引擎测试，也未构建或发布新产品版本。

## 微信输入法扩展对照（用户确认后）

用户明确同意临时停用 `com.tencent.inputmethod.wetype.FinderSync`（2.2.2）。使用带 `finally` 恢复及 180 秒超时的脚本，测试完成后主动发送恢复信号。未退出或卸载输入法，未重启 Finder，未修改云盘文件。

| 步骤 | 实际结果 |
| --- | --- |
| 状态核对 | 微信扩展从 `+` 变为 `-`；RightMouse 0.2.1 保持 `+` |
| 云盘根目录，Documents 文件夹右键 | 仍无 RightMouse 菜单；系统服务菜单存在 |
| 云盘 Documents 子目录，空白处右键 | 仍无 RightMouse 菜单 |
| 本地夹具，文件右键 | RightMouse 新建文件、打开方式、复制路径、剪切、复制到、移动到和设置正常；微信「隔空传送」菜单消失，证明停用在 Finder 中生效 |
| 主动结束对照 | 恢复脚本成功退出；微信与 RightMouse 扩展均为 `+` |
| 恢复后重新右键 | 「隔空传送」重新出现，RightMouse 菜单正常 |

本轮没有重新注册最小探针；使用上一轮同一已安装发行版完成第三方扩展的单变量对照。诊断应用仍保持注销、删除状态。

## 资料与解释边界

- [Apple Finder Sync 文档](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)：菜单依赖监控范围；工具栏在范围之外可显示，但不保证取得当前目标 URL。
- [Apple 开发者论坛](https://developer.apple.com/forums/thread/756711)：工程师说明部分目录和多扩展覆盖有限制；第三方开发者报告 iCloud Drive 不能监控。这是排查线索，不能替代本机对照，也不代表所有 macOS 版本均相同。

后续已实现五个系统 Services 兼容入口，详见 [服务验证记录](services-compatibility-validation.md)。它不改变本页对 Finder Sync 覆盖范围的结论；不得因菜单缺失建议用户购买开发者账号或授予完整磁盘访问权限。
