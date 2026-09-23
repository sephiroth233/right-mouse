# 应用品牌与菜单图标验证

日期：2026-09-23。关联 NFR-005、T017、T021、AC-029。用户要求应用内部和 Finder 右键菜单增加小图标，并设计独立应用图标。

## 目录

- [1. 设计与实现](#1-设计与实现)
- [2. 验证与交付](#2-验证与交付)
- [3. 验证边界](#3-验证边界)
- [4. 台前调度占位图修复](#4-台前调度占位图修复)
- [参考](#参考)

## 1. 设计与实现

使用 imagegen 内置工具生成蓝青色玻璃底座、白色指针与半透明右键菜单的品牌图标。透明背景原图保存在 Resources/Brand/RightMouseIcon.png，完整提示词在同目录 prompt.txt。脚本仅缩放和封装，不修改原画面；原图保持可编辑来源，ICNS 包含 16–1024 px、1x/2x 的十个表示。

宿主与 Finder 扩展均打包 AppIcon.icns，并设置 CFBundleIconFile；命令行构建和 Xcode resources phase 使用相同资源。应用侧栏、Dock 和 RightMouse 菜单根使用品牌图标。状态栏保留单色指针以适应系统外观。

MenuIcon 统一映射新建、文本复制、剪切、粘贴、复制到、移动到、目录和模板类型的 SF Symbols。应用菜单管理、预览、模板列表和文件操作台采用相同符号；文字标签保留，装饰性图像不重复朗读。操作台按钮按可用宽度换行，继续受右侧滚动容器约束。

打开方式页面和应用内菜单使用 NSWorkspace 返回的已安装应用图标并缓存；扩展在菜单回调外预载 Terminal/VS Code 图标。未安装应用回退通用符号。扩展不读取宿主私有配置，自定义应用条目仍使用通用图标，保持现有菜单快照的隐私范围。

## 2. 验证与交付

scripts/build-icons.sh 生成全部尺寸 PNG。受限环境中的 iconutil 首次报 Invalid Iconset；允许系统图标编码服务后封装成功。NSImage 实际解码得到 1024、512、512、256、256、128、64、32、32、16 px 十个表示，原图保留 alpha。检查了生成原图和 128 px 缩略版本，指针与菜单形状可辨认。

运行系统符号检查发现 folder.badge.arrow.forward 不存在，改为 arrow.right.doc.on.clipboard 后，当前映射涉及的 21 个 SF Symbols 全部可加载。该检查针对本机系统，不代表最低 macOS 14 的逐项视觉验收。

scripts/package-app.sh --development 编译宿主和扩展成功，签名结构检查通过。Xcode 工程重新生成并通过 plutil 检查。宿主与扩展资源的 SHA-256 均与源 ICNS 相同：106f10889611a542c71fbeaafa2d2eb0f3fcef7a50c8c7b6039609740c883f3e。

最终开发 ZIP SHA-256：7a4a4cf3fc6e0f74a401de54f2c4882356322201112b03cdb1604a52e487d75e。Finder 扩展已使用 pluginkit 重新登记。

## 3. 验证边界

首轮图标构建已通过原生工具打开，通用页及打开方式页的可访问性树可正常读取。截图仍仅返回台前调度缩略图，随后通道报告 native pipe closed，重连与 reset 后仍失败；未取得完整界面或新右键菜单的可靠像素级截图，也未能确认最后一次符号名称修正后主应用已重启。因此不将完整视觉、深浅色或 VoiceOver 验收标记通过；必要时退出后重新打开最终包验收。

本轮只修改展示和资源打包，未修改命令执行、文件引擎或权限逻辑，不重复执行无关文件操作回归；此前 341 核心、408 宿主检查是上一轮功能证据，不记作本轮新执行结果。

## 4. 台前调度占位图修复

用户反馈台前调度缩略图左下角仍为系统网格占位图。只读检查确认 Launch Services 的 CFBundleIconFile 与资源路径正确；NSWorkspace.icon(forFile:) 和运行实例 NSRunningApplication.icon 均返回新品牌图，说明并非 ICNS 缺失。运行进程仍来自前一次构建，最后一次构建曾在该进程运行期间覆盖应用包。

将 applicationIconImage 的设置从 applicationDidFinishLaunching 提前到 NSApplication.shared 初始化之后、setActivationPolicy(.regular) 之前，使 Dock 与台前调度创建应用条目前就有品牌图标。仅刷新本项目应用的 Launch Services 登记，并停止旧开发进程后重新构建，避免再次覆盖运行中的可执行文件。没有重置全局图标缓存。

修复版开发构建、签名及打包通过，ZIP SHA-256 为 3109d9e139a73b98193e704a80842332172f84a25f8ba683afa7fe184a3d09e6，替代第 2 节此前的开发包。原生工具成功重新启动应用并读取通用页、扩展已启用状态。窗口截图只包含缩略窗口本身，没有包含系统绘制的左下角应用徽标；读取 Dock 界面超时，所以该徽标的最终视觉刷新仍待用户验收，不能将它记为已验证通过。

## 参考

- [品牌资源说明](../../../Resources/Brand/README.md)
- [液态玻璃与窗口布局](EV-liquid-glass-001.md)
- [本机 Finder 模式](EV-local-finder-001.md)
- [Apple：应用图标](https://developer.apple.com/design/human-interface-guidelines/app-icons)
