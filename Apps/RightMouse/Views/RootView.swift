import SwiftUI
import AppKit
import RightMouseCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用", tools = "文件操作台", menus = "菜单管理", templates = "新建文件", favorites = "常用目录", applications = "打开方式", operations = "文件操作", diagnostics = "权限与诊断", tasks = "任务记录"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .tools: return "cursorarrow.click.2"
        case .menus: return "list.bullet.indent"
        case .templates: return "doc.badge.plus"
        case .favorites: return "folder.badge.gearshape"
        case .applications: return "square.grid.2x2"
        case .operations: return "arrow.left.arrow.right"
        case .diagnostics: return "checkmark.shield"
        case .tasks: return "clock.arrow.circlepath"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "让常用文件操作，就在右键菜单里。"
        case .tools: return "选择文件与目标目录，使用和 Finder 菜单相同的操作服务。"
        case .menus: return "只留下常用操作，按你的习惯排列。"
        case .templates: return "用真实模板创建文件，保留格式与初始内容。"
        case .favorites: return "收藏经常使用的文件夹，一步打开或整理文件。"
        case .applications: return "在终端、编辑器或其他应用中继续工作。"
        case .operations: return "设置冲突处理，查看文件操作的行为。"
        case .diagnostics: return "管理 Finder 扩展、目录范围与访问权限。"
        case .tasks: return "查看每一项结果，取消等待中的操作或核对未完成任务。"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @ViewState private var page: SettingsPage? = .general
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click.2").font(.title).foregroundStyle(.blue)
                    VStack(alignment: .leading) { Text("RightMouse").font(.headline); Text("Finder 效率工具").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 14).padding(.top, 22)
                List(SettingsPage.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                    .listStyle(.sidebar)
                Label(model.extensionEnabled ? "扩展已启用" : "等待启用扩展", systemImage: model.extensionEnabled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption).foregroundStyle(model.extensionEnabled ? .green : .secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }.navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                let current = page ?? .general
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.rawValue).font(.largeTitle.weight(.semibold))
                    Text(current.subtitle).foregroundStyle(.secondary)
                }.padding(28)
                if let notice = model.notice {
                    HStack { Image(systemName: "info.circle"); Text(notice).font(.callout); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示") }
                        .padding(12).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 28).padding(.bottom, 12)
                }
                if model.isReadOnly { Text("配置版本不兼容，当前为只读。原始文件已保留。请使用支持此配置的应用版本。").foregroundStyle(.orange).padding(.horizontal, 28) }
                Group {
                    switch current {
                    case .general: GeneralSettingsView(model: model, navigate: { page = $0 })
                    case .tools: FileToolsView(model: model)
                    case .menus: MenuSettingsView(model: model)
                    case .templates: TemplateSettingsView(model: model)
                    case .favorites: ScrollView { LocationSettingsView(model: model, watched: false) }
                    case .applications: ApplicationSettingsView(model: model)
                    case .operations: OperationSettingsView(model: model)
                    case .diagnostics: DiagnosticsSettingsView(model: model)
                    case .tasks: TasksView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 570)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshDiagnostics() }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("好", role: .cancel) { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    var navigate: (SettingsPage) -> Void
    var body: some View {
        Form {
            Section("开始使用") {
                SetupStep(number: 1, title: "启用 Finder 扩展", subtitle: model.extensionEnabled ? "扩展已启用，可继续选择覆盖目录。" : "在系统设置中启用 RightMouse Finder 扩展。", complete: model.extensionEnabled) { model.showExtensionSettings() }
                SetupStep(number: 2, title: "选择使用目录", subtitle: "已配置 \(model.configuration.watchedLocations.count) 个目录；子文件夹一并覆盖。", complete: !model.configuration.watchedLocations.isEmpty) { navigate(.diagnostics) }
                SetupStep(number: 3, title: "定制右键菜单", subtitle: "新建文件、复制路径、剪切移动与打开方式。", complete: false) { navigate(.menus) }
            }
            Section("偏好设置") {
                Toggle("登录时启动 RightMouse", isOn: Binding(get: { model.configuration.launchAtLogin }, set: model.setLaunchAtLogin))
                Toggle("新建文件后在 Finder 中定位", isOn: model.binding(\.revealCreatedFile))
                Toggle("将所有操作收进一个紧凑菜单", isOn: model.binding(\.compactMenu))
            }.disabled(model.isReadOnly)
            Section {
                LabeledContent("版本", value: "0.1.0 · 开发版")
                Text("开发版用于本机验证。正式签名、公证和各系统兼容性以交付验证记录为准。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct SetupStep: View {
    let number: Int
    let title: String
    let subtitle: String
    let complete: Bool
    var action: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            ZStack { Circle().fill(complete ? Color.green.opacity(0.12) : Color.blue.opacity(0.10)).frame(width: 32, height: 32)
                if complete { Image(systemName: "checkmark").foregroundStyle(.green) } else { Text("\(number)").font(.headline).foregroundStyle(.blue) }
            }
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Button(complete ? "管理" : "设置", action: action)
        }.padding(.vertical, 6)
    }
}

private struct OperationSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("同名文件") {
                Picker("默认处理方式", selection: model.binding(\.conflictPolicy)) { Text("每次询问").tag("ask"); Text("保留两份").tag("keepBoth"); Text("跳过").tag("skip") }
                Text("不会覆盖已有文件，也不会自动合并目录。保留两份会为新文件增加序号。").font(.caption).foregroundStyle(.secondary)
            }
            Section("剪切与粘贴") {
                Text("剪切时仅暂存选择；粘贴后才执行移动。成功项目从列表清除，失败或跳过项目保留。其他应用改写剪贴板后，待移动列表失效。")
                Text("退出应用后不会自动恢复活动剪切列表。未完成任务通过任务记录核对。").foregroundStyle(.secondary)
            }
            Section("跨磁盘移动") {
                Text("先复制并校验，再尝试清理来源。无法证明来源可安全清理时保留两份，并显示“源保留”。")
                Text("取消只影响未完成的工作，不会自动回滚已完成项目。撤销仅对满足身份校验条件的同卷移动开放。").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.isReadOnly)
    }
}

private struct DiagnosticsSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    HStack { Label(model.extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展未启用", systemImage: model.extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(model.extensionEnabled ? .green : .orange); Spacer(); Button("打开扩展设置") { model.showExtensionSettings() }; Button("刷新") { model.refreshDiagnostics() } }
                    Text("启用后，在下方配置的普通本地目录中打开 Finder 右键菜单。云盘位置的实际支持以系统与提供方验证结果为准。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                Text("右键菜单覆盖目录").font(.headline)
                LocationSettingsView(model: model, watched: true)
                GroupBox("权限说明") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("选择目录后保存安全书签；访问失败时，请使用“重新选择”修复。启用扩展不会自动授予所有文件的读写权限。")
                        Text("终端联动可能在首次使用时请求自动化权限。基础文件操作不要求辅助功能或完全磁盘访问权限。")
                        Text("诊断摘要仅含系统版本、组件状态和数量，不包含文件内容、路径或书签。").font(.caption).foregroundStyle(.secondary)
                        Button("复制诊断摘要") { model.copyDiagnostics() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }
}
