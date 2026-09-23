# RightMouse 品牌图标

蓝青色玻璃底座、白色鼠标指针与半透明右键菜单，表达 Finder 右键工具的用途。2026-09-23 使用 imagegen 内置工具生成，未使用 CLI/API 密钥方式。

## 目录

- [素材与构建](#素材与构建)
- [使用规则](#使用规则)
- [参考](#参考)

## 素材与构建

- RightMouseIcon.png：1254×1254、RGBA 透明背景原图。
- [生成提示词](prompt.txt)：保存完整生产提示词，实际生成尺寸以原图元数据为准。
- [AppIcon.icns](../AppIcon.icns)：包含 16、32、64、128、256、512、1024 px 的 macOS 多分辨率资源。
- 在项目根目录运行 scripts/build-icons.sh，以 sips 重采样、iconutil 封装；此步骤不修改原始画面。受限工具环境中 iconutil 需要访问系统图标编码服务。

## 使用规则

主应用和 Finder 扩展都打包 AppIcon.icns；Dock 与系统应用图标由 CFBundleIconFile 指定，应用侧栏及 RightMouse 菜单根使用同一品牌图标。状态栏保持单色系统符号以适配明暗外观。

功能图标使用系统 SF Symbols，语义映射集中在 MenuIcon；打开方式使用已安装应用的真实图标，找不到时回退终端或应用符号。Finder 在菜单回调之外预载 Terminal/VS Code 图标，不在构造菜单时做应用查询。自定义应用在宿主显示真实图标，扩展因快照不携带应用路径而使用通用符号。

## 参考

- [项目说明](../../README.md)
- [Apple：应用图标](https://developer.apple.com/design/human-interface-guidelines/app-icons)
