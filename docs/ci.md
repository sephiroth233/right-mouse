# GitHub 自动构建

## 目标与范围

GitHub Actions 复用本机预览版脚本，检查代码并分别生成 Apple Silicon（arm64）和 Intel（x86_64）DMG。使用临时构建签名，不需要 Apple Developer 账号、证书 Secrets 或 App Group。产物不经过 Apple 公证。

触发条件为推送到 `main`、以 `main` 为目标的 Pull Request、推送 `v*` 版本标签，以及 Actions 页面手动运行。日常构建保存到 Artifacts；版本标签构建会在两个架构均通过后自动发布 GitHub 预览发行版。工作流不推送提交或创建标签。手动运行入口需要工作流已存在于默认分支。

## 流程与验收条件

1. 在 Ubuntu 上使用 Python 3.12 运行 SDD 文档、JSON Schema 和追踪关系校验。
2. 文档检查通过后，分别在 `macos-26`（arm64）与 `macos-26-intel`（x86_64）执行核心和宿主检查。任一检查失败，该架构不产出可下载安装包。
3. 使用镜像默认 Xcode；记录工具链，要求 macOS SDK 26 或更新，以编译液态玻璃 API。最低部署目标仍为 macOS 14。
4. 运行 `build-local-app.py` 编译、临时签名，再运行 `package-local-app.sh --no-build` 打包。
5. 校验宿主、Finder 扩展和连接服务的架构、嵌套签名、DMG 镜像及 SHA-256；保存提交、版本、SDK 和构建身份元数据。
6. 上传 DMG、SHA-256、构建信息，保留 14 天；构建日志即使失败也上传，保留 7 天。同一分支或 PR 的新运行取消尚未完成的旧运行。

检查和构建任务仅授予 `contents: read`；仅版本标签的发布任务授予 `contents: write`。第三方 Actions 固定到完整提交 SHA，checkout 不持久化仓库凭据。PR 使用普通 `pull_request` 事件。只上传明确列出的发行文件和日志，不上传整个构建目录、临时钥匙串或私钥。

## 下载与使用

已发布版本从仓库右侧 **Releases（发行版）** 下载匹配架构的 DMG。日常构建在 **Actions → Build macOS DMG → 对应运行 → Artifacts** 下载。解压 Actions 产物后，按[安装说明](local-install.md)安装其中的 DMG。

每个架构单独生成完整配套的宿主、扩展和服务；升级时替换整个应用，不混用不同运行中的组件。Actions 产物有保留期限，Releases 资产不受该期限影响。

## 发布版本

更新应用版本和 [发行说明](release-notes.md)后，创建并推送 `vX.Y.Z` 或 `vX.Y.Z-local.N` 标签。标签中的 `X.Y.Z` 必须与构建产物中的应用版本一致；当前构建脚本的版本为 `0.2.0`。建议使用带注释标签，每次预览发布递增 `local.N`，不要移动已发布标签。

标签触发两种架构重新构建。发布任务仅下载同次运行的安装包，检查两个架构齐全、源码提交和版本匹配、DMG 校验和正确，再暂存六个发行附件。先创建草稿并上传全部附件，成功后公开为预览版；上传失败保持草稿，重试只能更新草稿，不覆盖已发布资产。当前发布路线始终标记预览版，Apple 公证发行需另行配置。

首次 `v0.2.0-local.1` 使用已通过的运行 `35820867854` 的两个原始安装包，标签指向对应源码 `f3b1bd4`，通过相同的准备和发布脚本归档；后续标签使用工作流自动发布。

## 验证边界

本地可以检查 YAML、表达式、脚本与文档，并验证已有构建脚本。GitHub 托管 runner 的首次完整运行，需要工作流推送后验证。CI 不注册 Finder 扩展、不启动用户级连接服务，不把自动检查通过等同于真实 Finder、首次安装或最低系统版本验收。

2026-09-23 本地验证：actionlint 1.7.12（含 ShellCheck）通过，所有构建步骤的 Bash 语法检查通过，SDD 校验通过；直接提取工作流的包验证步骤，对现有 arm64 应用与 DMG 执行签名、三个组件架构、镜像和散列检查均通过。故意设置错误架构时按预期返回失败，`tee` 不会掩盖失败状态。Intel 和托管 runner 的执行结果尚未取得，未触发任何远程运行。

## 首次远程运行与修复

[首次运行](https://github.com/sephiroth233/right-mouse/actions/runs/35820321920)发现两个独立问题：

- arm64 的编译、核心和宿主检查通过，但 `codesign` 报 `no identity found`。临时钥匙串仅传给 `--keychain`，未加入用户搜索列表；该选项不会替代证书链解析时使用的搜索列表。脚本现临时加入钥匙串、检查证书与私钥身份匹配，结束时恢复原列表并删除临时材料，不增加根证书信任。
- Intel 核心检查报 `Failed to retrieve app-scope key`。Intel 链接得到的命令行测试程序没有自动签名，书签测试缺少代码身份。在本机以 Rosetta 运行同一 Intel 最小程序，未签名失败、ad-hoc 签名后成功；核心与宿主检查脚本现均显式签名并验证测试程序，未跳过书签测试或改动文件访问规则。

修复提交 `f3b1bd4` 的[第二次运行](https://github.com/sephiroth233/right-mouse/actions/runs/35820867854)已全部通过：文档检查，以及两个架构各自的 384 项核心、472 项宿主检查、应用编译签名、DMG 打包、架构/签名/镜像/散列验证。产物为 `RightMouse-local-arm64-2` 与 `RightMouse-local-x86_64-2`，另有对应构建日志。以上取代上一节“尚未取得托管执行结果”的初始记录；Finder UI 和首次安装仍需单独验收。

## 参考

- [GitHub 托管 runner 与架构](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [macOS 26 ARM 镜像工具链](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [macOS 26 Intel 镜像工具链](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
- [Artifact 上传与保留设置](https://github.com/actions/upload-artifact)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
