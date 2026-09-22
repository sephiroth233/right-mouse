# RightMouse

原生 macOS Finder 右键效率工具，使用 SwiftUI、AppKit 和 FinderSync 实现。当前是开发版本：已有宿主、真实 Finder 扩展与文件操作引擎，系统接入与发布验收仍在进行。

## 开发与验证

在 macOS 安装 Command Line Tools 后运行：

```sh
scripts/check-core.sh
scripts/build-app.sh
open .build/native/RightMouse.app
```

核心检查使用随机临时目录，覆盖命令协议、配置、模板、菜单和文件操作。NSFileCoordinator 需要可访问系统文件协调服务；受限执行环境中的连接失败不能视为文件测试通过。

`scripts/package-app.sh --development` 生成开发 ZIP。完整 Xcode 工程为 `RightMouse.xcodeproj`；新增 Swift 文件后运行 `python3 Config/generate-project.py`。标准 XCTest 和正式签名步骤见 [构建说明](Config/README.md)。

## 当前能力

- 新建 TXT、Markdown、JSON、YAML、HTML、Shell 文件，导入自定义模板。
- 复制路径、名称、无扩展名名称和 Shell 引用格式。
- 剪切会话、粘贴移动、复制到和移动到指定目录。
- 重名时跳过或保留两份；移动前校验，跨卷先提交目标再核对来源。
- 收藏目录、Terminal、VS Code 与自定义应用入口。
- 菜单开关、排序、分组、预览、任务进度与恢复核对界面。

首次使用需在应用中选择使用目录，并在系统扩展设置中确认 Finder 扩展状态。扩展仅对配置目录提供菜单。目录授权来自系统选择器；配置中的路径文字本身不代表授权。

## 实现结构

```mermaid
flowchart LR
    Finder[Finder 菜单] --> Extension[FinderSync 扩展]
    Extension --> Inbox[共享请求队列]
    Inbox --> Host[原生宿主与调度器]
    Host --> Core[文件操作和模板核心]
    Host --> Ledger[持久任务记录]
    Core --> Recovery[逐项恢复日志]
    Host --> UI[设置与任务界面]
```

扩展捕获每次菜单的独立上下文，入队并唤醒宿主；宿主验证请求、授权范围和重复请求，再串行执行文件变更。操作记录不完整时要求核对，不自动重新执行。恢复页中的人工确认只保存核对记录，不删除文件，也不把原来的失败改写为成功。

## 当前验证边界

105 项核心夹具检查和 16 项真实宿主集成检查通过，详情见 [核心证据](specs/001-finder-core/evidence/EV-core-checks-001.md) 与 [原生整合证据](specs/001-finder-core/evidence/EV-native-build-001.md)。宿主与嵌入扩展已实际编译，开发签名结构验证通过；Finder 登记和进程加载证据见 [接入记录](Config/validation/finder-load-2026-09-22.md)。

尚未完整通过：真实 Finder 菜单到宿主的端到端操作、所有权限撤回场景、真实双卷/外置卷故障、最低 macOS 版本、完整键盘与 VoiceOver 验收、Developer ID 签名及公证。当前机器没有有效分发证书，也未安装完整 Xcode。开发包不等于已公证发行版。

## 规格与版本管理

- [设计方案](docs/design-plan.md)
- [SDD 索引](docs/sdd/README.md)
- [施工任务与进度](specs/001-finder-core/tasks.md)
- [验收清单](specs/001-finder-core/checklists/acceptance.md)

按可验证里程碑提交 Git：规格基线、核心与回归检查、原生宿主与扩展、接入修复、验收和发行。每次提交保留对应证据；未完成的验收保持未完成。
