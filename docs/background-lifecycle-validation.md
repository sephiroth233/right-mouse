# 启动与后台驻留验证（2026-09-23）

## 实现约定

- 底部 Dock 与顶部菜单栏分开控制。通用设置新增“启动与后台运行”区域和“在菜单栏显示图标”开关，默认显示，修改立即发布并保存；旧配置缺少字段时默认显示。
- 应用以 `LSUIElement` / accessory 启动，避免登录或 Finder 后台唤醒时先显示 Dock。根据 Apple `kAEOpenApplication` 事件中的登录项标记判断静默启动，而非依据用户是否勾选了开机启动。
- 手动打开、重新打开及设置入口恢复 regular 策略并显示设置。关闭最后一个设置/核对窗口后回到 accessory，进程和已有服务连接继续保留。最小化仍保留 Dock。
- 延迟启动回调不会重开已经展示后被用户关闭的窗口。后台初始化错误先保留为设置提示，避免登录时打断；用户文件操作的必要错误提示仍保留。
- 菜单栏与 Dock 都隐藏时，用户仍可从 Spotlight、Applications 或 Finder 的设置入口找回；退出通过“退出 RightMouse”或 Cmd+Q。

## 自动检查

- `scripts/check-host.sh`：514 项通过；新增 14 项验证登录 Apple event、手动启动、Finder 唤醒、重复展示抑制、菜单栏设置发布/保存以及只读配置不能修改系统登录项。
- `scripts/check-core.sh`：387 项通过；新增 3 项验证菜单栏默认值、旧配置迁移及关闭后重新加载。
- 完整宿主、Finder 扩展及 XPC 服务本机构建成功，嵌套代码签名验证通过。
- SDD 文档校验和 `git diff --check` 通过。

## 隔离窗口交互

使用同一构建中的宿主建立 `cn.rightmouse.LifecyclePreview` 测试副本，移除扩展和连接服务并使用独立数据目录，没有替换 `/Applications/RightMouse.app` 或更改用户真实登录项。

1. 普通打开显示设置，转换控件包含“登录时启动 RightMouse”和“在菜单栏显示图标”。
2. 菜单栏开关在 on/off 间即时改变，独立配置文件持久化对应布尔值。
3. 红叉关闭后 PID 6797 仍在，`activationPolicy` 从 regular(0) 切换 accessory(1)。再次打开同一 PID 恢复 regular(0) 和设置窗口，开关状态保持。
4. 最小化后同一进程保持 regular(0)；再次打开可以恢复设置控件。
5. Cmd+Q 后原 PID 消失。以 `--finder-wake` 后台重启得到新 PID 7930，保持 accessory(1)，隐藏菜单栏的配置仍为 false；随后手动打开恢复 regular(0)，设置控件仍为 off。
6. 验收预览通过 Cmd+Q 退出。实际用户应用与配置未替换。

图形工具在台前调度下返回缩略图，本轮界面核对以原生控件树及只读进程激活策略为依据，没有将缩略图计为完整截图验收。顶部图标的持久化和订阅更新已检查，完整视觉截图仍待人工复核。

## 尚未验收

- 没有注销或重启用户 Mac；真实 `SMAppService` 登录项触发、系统审批及跨系统登录行为仍需验收。构造登录 Apple event 的自动检查不能替代真实登录。
- 没有以隔离预览替代真实 Finder 扩展交互验收；该副本未注册扩展或 XPC 服务。
- 按用户要求仅本地构建和 Git 提交，不生成 DMG、不推送、不发布 GitHub 版本。

依据：[Apple 登录项启动事件](https://developer.apple.com/documentation/coreservices/keyaelaunchedasloginitem)。
