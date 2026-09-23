import SwiftUI
import AppKit
import RightMouseCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用", tools = "文件操作台", menus = "菜单管理", templates = "新建文件", favorites = "常用目录", recent = "最近目标", applications = "打开方式", operations = "文件操作", diagnostics = "权限与诊断", tasks = "任务记录"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .tools: return "cursorarrow.click.2"
        case .menus: return "list.bullet.indent"
        case .templates: return "doc.badge.plus"
        case .favorites: return "folder.badge.gearshape"
        case .recent: return "clock.badge.checkmark"
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
        case .recent: return "最近使用的十个目标目录，选择后可继续整理文件。"
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
        GeometryReader { viewport in
            content.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
    }
    private var content: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click.2").font(.title).foregroundStyle(.blue)
                    VStack(alignment: .leading) { Text("RightMouse").font(.headline); Text("Finder 效率工具").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 18).padding(.top, 24)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(SettingsPage.allCases) { item in
                            Button { page = item } label: {
                                Label(item.rawValue, systemImage: item.icon)
                                    .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 11)
                                    .background(page == item ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 11))
                                    .contentShape(RoundedRectangle(cornerRadius: 11))
                            }.buttonStyle(.plain)
                                .foregroundStyle(page == item ? Color.accentColor : .primary)
                                .accessibilityAddTraits(page == item ? .isSelected : [])
                        }
                    }.padding(.horizontal, 10)
                }
                Label(model.isLocalFinderMode ? (model.extensionEnabled ? "本机菜单，扩展已启用" : "本机模式，等待启用") : model.isDevelopmentStorage ? "开发模式，Finder 不可用" : (model.extensionEnabled ? "扩展已启用" : "等待启用扩展"), systemImage: model.isDevelopmentStorage ? "exclamationmark.triangle" : (model.extensionEnabled ? "checkmark.circle.fill" : "circle.dashed"))
                    .font(.caption).foregroundStyle(model.isDevelopmentStorage ? .orange : (model.extensionEnabled ? .green : .secondary))
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }.frame(width: 204).rightMouseGlass(radius: 22)
            VStack(alignment: .leading, spacing: 0) {
                let current = page ?? .general
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.rawValue).font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text(current.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
                if model.isDevelopmentStorage {
                    Label(model.isLocalFinderMode ? "本机模式 · Finder 使用内置菜单，文件操作将在应用中确认。" : "开发模式 · Finder 菜单暂不可用。可在文件操作台使用本地功能。", systemImage: "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(12).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24).padding(.bottom, 12)
                }
                if let notice = model.notice {
                    HStack { Image(systemName: "info.circle"); Text(notice).font(.callout); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示") }
                        .padding(12).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24).padding(.bottom, 12)
                }
                if model.isReadOnly { Text("配置版本不兼容，当前为只读。原始文件已保留。请使用支持此配置的应用版本。").foregroundStyle(.orange).padding(.horizontal, 28) }
                Group {
                    switch current {
                    case .general: GeneralSettingsView(model: model, navigate: { page = $0 })
                    case .tools: FileToolsView(model: model)
                    case .menus: MenuSettingsView(model: model)
                    case .templates: TemplateSettingsView(model: model)
                    case .favorites: ScrollView { LocationSettingsView(model: model, watched: false) }
                    case .recent: RecentDestinationsView(model: model) { page = .tools }
                    case .applications: ApplicationSettingsView(model: model)
                    case .operations: OperationSettingsView(model: model)
                    case .diagnostics: DiagnosticsSettingsView(model: model)
                    case .tasks: TasksView(model: model)
                    }
                }.frame(minWidth: 0, maxWidth: 960, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .scrollIndicators(.visible, axes: .vertical)
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(16)
        .background(RightMouseBackdrop())
        .groupBoxStyle(RightMouseGroupBoxStyle())
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
                SetupStep(number: 1, title: "启用 Finder 扩展", subtitle: model.isLocalFinderMode ? (model.extensionEnabled ? "扩展已启用。请在普通本地目录右键验收内置菜单。" : "在系统设置中启用 RightMouse Finder 扩展。") : model.isDevelopmentStorage ? (model.extensionEnabled ? "扩展已登记，但共享通信不可用。" : "开发模式下共享通信不可用，Finder 菜单暂不可用。") : (model.extensionEnabled ? "扩展已启用，可继续选择覆盖目录。" : "在系统设置中启用 RightMouse Finder 扩展。"), complete: (!model.isDevelopmentStorage || model.isLocalFinderMode) && model.extensionEnabled) { model.showExtensionSettings() }
                SetupStep(number: 2, title: "选择使用目录", subtitle: model.isLocalFinderMode ? "本机菜单覆盖普通本地目录；此处目录配置用于共享模式。" : "已配置 \(model.configuration.watchedLocations.count) 个目录；子文件夹一并覆盖。", complete: !model.configuration.watchedLocations.isEmpty) { navigate(.diagnostics) }
                SetupExerciseView(model: model, showTasks: { navigate(.tasks) })
                SetupStep(number: 4, title: "定制右键菜单", subtitle: model.isLocalFinderMode ? "本机版采用固定菜单；自定义配置暂不传递到 Finder。" : "新建文件、复制路径、剪切移动与打开方式。", complete: false) { navigate(.menus) }
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
                    HStack { Label(model.isLocalFinderMode ? "本机 Finder 菜单（需实际验收）" : model.isDevelopmentStorage ? "开发模式：Finder 功能不可用" : (model.extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展未启用"), systemImage: !model.isDevelopmentStorage && model.extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(!model.isDevelopmentStorage && model.extensionEnabled ? .green : .orange); Spacer(); Button("打开扩展设置") { model.showExtensionSettings() }; Button("刷新") { model.refreshDiagnostics() } }
                    Text(model.storageDiagnostic ?? "启用后，在下方配置的普通本地目录中打开 Finder 右键菜单。云盘位置的实际支持以系统与提供方验证结果为准。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                Text("右键菜单覆盖目录").font(.headline)
                LocationSettingsView(model: model, watched: true)
                GroupBox("权限说明") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("选择目录后保存安全书签；访问失败时，请使用“重新选择”修复。启用扩展不会自动授予所有文件的读写权限。")
                        Text("终端联动可能在首次使用时请求自动化权限。基础文件操作不要求辅助功能或完全磁盘访问权限。")
                        Text("诊断摘要仅含系统版本、组件状态和数量，不包含文件内容、路径或书签。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("复制诊断摘要") { model.copyDiagnostics() }
                            Button("导出脱敏诊断") { model.exportDiagnostics() }
                        }
                        Text("诊断事件最多保留 7 天或 10 MiB，先达到的限制生效。导出文件仅含事件时间、组件、随机任务标识、操作类型、状态和错误码，不含文件名、路径、内容或安全书签。证据完整的终态任务在超过 30 天后清理；未完成、撤销、暂存或需要核对的记录继续保留。").font(.caption).foregroundStyle(.secondary)
                        if let summary = model.retentionSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }
}
