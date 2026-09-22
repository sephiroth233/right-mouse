# V1 开工与验证手册

提供从当前文档目录到可运行原生工程的操作顺序，并区分现在可运行的文档检查与未来工程命令。

读者：开发/测试；版本：0.1.0；基准日期：2026-09-22。本手册不会自动安装 Xcode、修改系统开发目录或替用户提交公证。

## 目录

- [1. 当前可执行检查](#1-当前可执行检查)
- [2. 开发环境准备](#2-开发环境准备)
- [3. 工程创建后的构建](#3-工程创建后的构建)
- [4. 真机验证流程](#4-真机验证流程)
- [5. 排查与交付记录](#5-排查与交付记录)
- [参考](#参考)

## 1. 当前可执行检查

在仓库根目录执行文档检查。脚本仅读取文档，不操作 Finder 或用户文件；JSON Schema 验证使用固定的文档工具依赖，建议放入临时虚拟环境。安装依赖需要网络，仅写入指定临时目录。

```bash
python3 -m venv /private/tmp/rightmouse-sdd-venv
/private/tmp/rightmouse-sdd-venv/bin/python -m pip install -r tools/requirements-docs.txt
/private/tmp/rightmouse-sdd-venv/bin/python scripts/validate_sdd.py
```

预期：Markdown 结构/本地链接/锚点、追踪编号、任务依赖、JSON Schema 和样例检查通过。负例被拒绝才算通过。该检查不验证 Finder 行为，也不运行尚不存在的应用测试。已有同名临时环境时复用前应确认归属；不使用全局 pip 安装。

## 2. 开发环境准备

只读检查命令可立即运行：

```bash
sw_vers
uname -m
xcode-select -p
xcodebuild -version
xcrun swift --version
```

当前已知 `xcodebuild` 因选中 Command Line Tools 而不可用。安装或找到完整 Xcode 后，可对单次命令指定真实路径，避免未经说明修改全局开发目录。例如实际安装位置确实为 `/Applications/Xcode.app` 时：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
```

T001 需要记录：Xcode 完整版本、SDK、Swift language mode、macOS deployment target=14.0、运行系统、CPU 架构、真实 Team/bundle/App Group 标识、签名类型和测试卷类型。账号、私钥、公证密码不得写入仓库。仅有 CLI 工具时，可以写纯逻辑与文档，不能宣布 Finder 扩展已验收。

## 3. 工程创建后的构建

以下命令依赖 T002 创建对应工程、Package 和 shared scheme；当前不可执行。它们是工程交付契约，T002 必须确保名称一致并替换为实际可复现的命令。

```bash
swift test --package-path Packages/RightMouseCore
xcodebuild -project RightMouse.xcodeproj -scheme RightMouse -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode build
xcodebuild -project RightMouse.xcodeproj -scheme RightMouse -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode test
```

前提：完整 Xcode 已被选中或为命令设置 DEVELOPER_DIR，开发签名和能力配置有效，scheme 已加入测试 target。副作用：写 `.build/` 编译产物；核心测试仅写独立夹具目录。T002 将 `.build/`、签名材料、本机用户配置加入忽略规则；不把构建失败归因于文档检查。

预期：Package 测试验证纯核心，Xcode 构建完成宿主与嵌入扩展，集成测试覆盖协议与系统适配。不要传入 `CODE_SIGNING_ALLOWED=NO` 后据此宣称扩展实际可加载。正式签名与公证命令在 T022 根据实际 Team/凭据存储生成，当前不放不可用占位密钥命令。

## 4. 真机验证流程

### 4.1 第一条可运行路径

1. 创建专用 `RightMouse-TestFixtures` 目录与 `Source`、`Destination` 子目录，内部只放测试数据。
2. 安装开发应用，按当前系统设置入口启用 Finder 扩展；在应用配置中选择夹具根目录。
3. 在 Source 空白处右键新建 Markdown，确认内容/命名，定位实际文件。
4. 复制路径并与实际 URL 比较；再用 VS Code 打开 Source。应用未安装时应获得可读失败反馈。
5. 剪切该文件，在 Destination 使用 RightMouse 粘贴，确认源与目标和任务结果一致。
6. 退出宿主，再通过 Finder 新建 TXT，检查冷启动和仅执行一次。

预期结果：所有操作指向明确目录；剪切阶段源未变化；移动完成后目标正确；宿主冷启动不打开无关设置页。失败时保留夹具与日志，按请求 ID 排查；不连续重试到“偶尔成功”。

### 4.2 高风险试验

跨卷使用专用测试 APFS 卷或测试磁盘镜像，exFAT 仅在有测试条件时加入矩阵。通过执行器的测试故障钩子在阶段边界注入异常，再用专用测试进程验证真实崩溃；测试钩子不得暴露为发布版本外部接口。

磁盘满、断开挂载、目录并发写入、源被替换、符号链接循环、损坏日志等试验都必须使用夹具。中断仅针对测试构建和测试卷，不终止用户 Finder 或卸载日常使用磁盘。试验结束先核对源/目标/日志，再人工清理夹具。

## 5. 排查与交付记录

| 现象 | 优先证据 | 下一步 |
| --- | --- | --- |
| 菜单不出现 | 系统版本、扩展启用、注册目录、签名和宿主/扩展版本 | 按矩阵区分云盘与本地；不立即扩大权限 |
| 菜单出现但创建失败 | requestID、访问进程、目标类型、TCC/文件错误码 | 针对该目录修复授权或写权限 |
| 点击无反应 | Inbox 是否提交、宿主唤醒、accepted/回执 revision | 同 ID 查询状态，不用新 ID 自动重跑 |
| 重启后出现两份文件 | 操作阶段、意图、来源/目标身份和摘要 | needsReview，保留两份并核对 |
| 进入终端路径错误 | 捕获上下文、适配器、结构化参数 | 复核多选语义和特殊字符；禁止拼接执行 |

证据示例模板（真正运行后才填写结果）：

```text
Evidence ID: EV-T015-AC021-001
Task / Requirement / Case: T015 / NFR-001 / AC-021
Build + macOS + filesystem: 待填
Fixture and injected failure: 待填
Expected: 取消后源保留，已提交目标如实展示
Actual: NOT_RUN
Logs / screenshots: 待填
Decision: 未验收
```

## 参考

- [任务清单](tasks.md)
- [验收清单](checklists/acceptance.md)
- [Apple Finder Sync 文档](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
