# 液态玻璃与启动窗口布局验证

落实用户补充的液态玻璃风格、启动居中和适中尺寸要求，记录代码验证与真机验证的边界。

日期：2026-09-22；关联 NFR-005、T017、T021、AC-029；状态：实现与编译通过，视觉和辅助功能实测未完成。

## 目录

- [1. 样式与窗口规则](#1-样式与窗口规则)
- [2. 验证结果](#2-验证结果)
- [3. 未完成验收](#3-未完成验收)
- [参考](#参考)

## 1. 样式与窗口规则

macOS 26 及以上在导航面板和菜单预览采用 SwiftUI 原生 `glassEffect(.regular)`。旧系统采用系统材质，背景由 NSVisualEffectView 提供随窗口激活状态变化的磨砂效果。开启减少透明度或增强对比度时，玻璃面板和窗口底色切换为实色。内容区、任务文本保留稳定阅读底色，避免每层叠加玻璃。

主窗口默认外框 960×680 pt，任务窗口 760×560 pt。优先使用鼠标所在屏幕；按 `NSScreen.visibleFrame` 的中点设置窗口位置，避开菜单栏和 Dock。小屏每边预留 24 pt，尺寸不足时缩小；普通屏幕主窗口最小外框为 820×540 pt。关闭后重新打开按保留的尺寸居中；已显示窗口的切页或激活不会改变位置。无屏幕信息时保留系统行为。

导航面板宽 204 pt，面板圆角 22 pt，内容区设最大宽度后居中。菜单预览的宽度允许收缩，任务页不再用固定最小宽度撑开主窗口。

## 2. 验证结果

运行 `python3 Config/generate-project.py` 生成包含 10 个宿主 Swift 源文件的工程，`plutil` 验证通过。运行 `scripts/package-app.sh --development` 编译 macOS 14 部署目标宿主与 Finder 扩展，开发签名结构校验通过，生成新版开发 ZIP。编译器已检查 macOS 26 API 的 availability 分支。

本次 `dist/RightMouse-0.1.0-development.zip` 的 SHA-256 为 `6d981a442a64bbb53914ef4ddf2e724e3308beb41c7bf31a7f01c11200b8d8bd`，替代此前同路径开发包；旧构建证据中的校验值仅对应旧版本。

以真实 `WindowLayout.centeredFrame` 函数计算以下场景，返回窗口均在可用区域内且中心坐标一致。该检查只验证几何计算，输入是模拟屏幕矩形，不代表已经连接相应显示器实测。

| 可用区域 x/y/宽/高（pt） | 窗口 x/y/宽/高（pt） | 结果 |
| --- | --- | --- |
| 0 / 48 / 1440 / 827 | 240 / 121.5 / 960 / 680 | 居中且未越界 |
| -1920 / 30 / 1920 / 1020 | -1440 / 200 / 960 / 680 | 负坐标外接屏计算通过 |
| 0 / 24 / 1024 / 700 | 32 / 48 / 960 / 652 | 高度收敛且居中 |
| 0 / 0 / 800 / 600 | 24 / 24 / 752 / 552 | 宽高收敛且居中 |

## 3. 未完成验收

原生自动化工具 reset 后重新连接仍返回 `Sky Computer Use native pipe closed before response`。因此本次没有取得新界面截图，也没有宣称深浅色、真实小屏内容、旧系统降级、减少透明度、键盘和 VoiceOver 已通过真机验收。AC-029 保持未通过，待原生通道恢复后核对全部页面、窗口首次显示与关闭重开行为。

本次只修改外观与窗口布局，未改动文件引擎、请求协议或授权逻辑；此前核心与宿主检查记录保持独立，不作为新外观的视觉证据。

## 参考

- [更新后的设计方案](../../../docs/design-plan.md)
- [验收清单](../checklists/acceptance.md)
- [Apple：自定义视图应用 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple：屏幕可用区域](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)
