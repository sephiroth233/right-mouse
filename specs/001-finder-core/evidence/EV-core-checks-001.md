# 核心模块第一次整合验证

对实际 Swift 核心代码运行可重复的协议、文件、模板和菜单夹具，记录已证明的范围与未证明的系统行为。

日期：2026-09-22；状态：105 项核心检查通过；构建来源为当前工作目录，后续版本由相应 Git 提交固定。目标用例范围见 [验收清单](../checklists/acceptance.md)。

## 目录

- [1. 构建与操作步骤](#1-构建与操作步骤)
- [2. 实际结果](#2-实际结果)
- [3. 证据边界](#3-证据边界)
- [参考](#参考)

## 1. 构建与操作步骤

使用 CLT Swift 6.4、language mode 5、macOS 14 部署目标构建 `RightMouseCheck`；2026-09-22 实际运行的是 SwiftPM debug 产物 `.build/out/Products/Debug/RightMouseCheck`。后续可使用 `bash scripts/check-core.sh` 独立编译执行，不依赖 XCTest。代码仅操作带随机 UUID 的临时目录，结束时清理，不写用户原始文件。

测试中的 NSFileCoordinator 需要访问 macOS filecoordinationd；在 Codex 文件沙盒内该系统连接失败，返回 Cocoa 512。同一测试程序经受控的沙盒外执行后成功。这一差异记录为测试环境约束，实现未绕过文件协调失败。

## 2. 实际结果

| 类别 | 数量 | 验证范围 |
| --- | --- | --- |
| 命令与存储 | 19 | 严格字段/版本、非法动作、过期/未来时间、选择上限、URL参数、重复请求、内容冲突、宿主锁、符号链接队列拒绝、路径文本 |
| 文件操作 | 16 | 同卷移动/撤销、结果与日志项目 ID 一致、no-clobber竞争、重名、目录后代、包/符号链接、特殊文件、取消、校验、源/目标变化、日志失败 |
| 菜单规则 | 6 | 场景、无目录、过期剪切、排序分组、容量、多目录选择 |
| 配置与模板 | 54 | 版本/备份/权限/上限、6种模板、内容和变量、无执行权限、非法来源、12个并发创建者 |
| 存储审查回归 | 10 | 私有目录权限、损坏记录隔离、未知版本、符号链接、超限、请求/回执 ID 与摘要校验 |

审查修复后再次执行 `bash scripts/check-core.sh`，产物为 `.build/core-checks/RightMouseCheck`。程序退出码为 0，最终输出：`PASS: 105 core fixture checks; real Finder, TCC, signing and multi-volume checks remain separate.` 所有测试使用真实库代码与实际临时文件；故障/跨卷分支通过测试钩子精确注入，发布入口不暴露这些钩子。

## 3. 证据边界

跨卷算法检查使用同卷夹具强制进入跨卷分支，不是第二个真实卷；真实外盘/exFAT、磁盘满/拔出、每阶段强杀、断电仍未验证。界面可访问性、Finder 菜单、系统授权和 App Group 能力不能由核心检查证明。

本结果支持对应任务的实现进度和部分验收子场景，不把包含真机步骤的整条 AC 标记为 PASS。恢复读取与条件撤销已有基础，但宿主完整恢复交互仍在整合。正式签名、公证和最低 macOS 支持不在本次通过范围内。

## 参考

- [状态模型](../data-model.md)
- [开工手册](../quickstart.md)
- [Apple 文件协调机制](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
