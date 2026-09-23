import SwiftUI
import AppKit
import RightMouseCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用", menus = "菜单管理", templates = "新建文件", applications = "打开方式", diagnostics = "权限与诊断"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .menus: return "list.bullet.indent"
        case .templates: return "doc.badge.plus"
        case .applications: return "square.grid.2x2"
        case .diagnostics: return "checkmark.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "让常用文件操作，就在右键菜单里。"
        case .menus: return "选择显示位置，整理你的右键菜单。"
        case .templates: return "用真实模板创建文件，保留格式与初始内容。"
        case .applications: return "在终端、编辑器或其他应用中继续工作。"
        case .diagnostics: return "管理 Finder 扩展、目录范围与访问权限。"
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
                    if let icon = AppIcons.brand {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 38, height: 38).accessibilityHidden(true)
                    } else { Image(systemName: "cursorarrow.click.2").font(.title).foregroundStyle(.blue).accessibilityHidden(true) }
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
                Label(model.localServiceReady ? "已连接" : (model.extensionEnabled ? "扩展已启用" : "等待启用"), systemImage: model.localServiceReady ? "circle.fill" : "circle.dashed")
                    .font(.caption).foregroundStyle(model.localServiceReady ? .green : .secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }.frame(width: 184).rightMouseGlass(radius: 22)
            VStack(alignment: .leading, spacing: 0) {
                let current = page ?? .general
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(current.rawValue).font(.system(size: 27, weight: .semibold, design: .rounded))
                        Spacer()
                        if current == .menus && model.localServiceReady { Label("已连接", systemImage: "circle.fill").font(.caption).foregroundStyle(.green) }
                    }
                    Text(current.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 24).padding(.vertical, current == .menus ? 18 : 24)
                if model.isDevelopmentStorage && !(current == .menus && model.localServiceReady) {
                    Label(model.isLocalFinderMode ? (model.authenticatedXPCBuild ? model.localServiceStatus : "本机模式 · Finder 使用内置菜单，文件操作将在应用中确认。") : "开发模式 · Finder 菜单暂不可用，请使用本机发行版连接 Finder。", systemImage: model.localServiceReady ? "checkmark.shield" : "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(12).background((model.localServiceReady ? Color.green : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
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
                    case .menus: MenuSettingsView(model: model)
                    case .templates: TemplateSettingsView(model: model)
                    case .applications: ApplicationSettingsView(model: model)
                    case .diagnostics: DiagnosticsSettingsView(model: model)
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
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    var navigate: (SettingsPage) -> Void
    var body: some View {
        Form {
            Section("开始使用") {
                SetupStep(number: 1, title: "启用 Finder 扩展", subtitle: model.isLocalFinderMode ? (model.extensionEnabled ? "扩展已启用。请在普通本地目录右键使用已配置的菜单。" : "在系统设置中启用 RightMouse Finder 扩展。") : model.isDevelopmentStorage ? (model.extensionEnabled ? "扩展已登记，但共享通信不可用。" : "开发模式下共享通信不可用，Finder 菜单暂不可用。") : (model.extensionEnabled ? "扩展已启用，可继续选择覆盖目录。" : "在系统设置中启用 RightMouse Finder 扩展。"), complete: (!model.isDevelopmentStorage || model.isLocalFinderMode) && model.extensionEnabled) { model.showExtensionSettings() }
                SetupStep(number: 2, title: "选择使用目录", subtitle: model.isLocalFinderMode ? "本机菜单覆盖普通本地目录；此处目录配置用于共享模式。" : "已配置 \(model.configuration.watchedLocations.count) 个目录；子文件夹一并覆盖。", complete: !model.configuration.watchedLocations.isEmpty) { navigate(.diagnostics) }
                SetupExerciseView(model: model)
                SetupStep(number: 4, title: "定制右键菜单", subtitle: model.isLocalFinderMode ? "选择常用操作放到 Finder 一级菜单，其余操作可收进子菜单。" : "新建文件、复制路径、剪切移动与打开方式。", complete: false) { navigate(.menus) }
            }
            if model.authenticatedXPCBuild {
                Section("本机连接") {
                    Text(model.localServiceStatus).font(.callout)
                    HStack {
                        Button("启用或修复连接") { model.onRepairLocalService?() }
                        Button("停用并移除服务") { model.onStopLocalService?() }
                    }
                }
            }
            Section("偏好设置") {
                Toggle("登录时启动 RightMouse", isOn: Binding(get: { model.configuration.launchAtLogin }, set: model.setLaunchAtLogin))
                Toggle("新建文件后在 Finder 中定位", isOn: model.binding(\.revealCreatedFile))
                Toggle("将未置顶的操作收进 RightMouse 子菜单", isOn: model.binding(\.compactMenu))
            }.disabled(model.isReadOnly)
            Section {
                LabeledContent("版本", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") + (model.authenticatedXPCBuild ? " · 本机版" : " · 开发版"))
                Text(model.authenticatedXPCBuild ? "无需开发者账号。本机版未经过 Apple 公证，首次安装请按随包说明允许运行。" : "开发版用于本机验证。正式签名、公证和各系统兼容性以交付验证记录为准。")
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

private struct DiagnosticsSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    HStack { Label(model.isLocalFinderMode ? "本机 Finder 菜单（需实际验收）" : model.isDevelopmentStorage ? "开发模式：Finder 功能不可用" : (model.extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展未启用"), systemImage: !model.isDevelopmentStorage && model.extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(!model.isDevelopmentStorage && model.extensionEnabled ? .green : .orange); Spacer(); Button("打开扩展设置") { model.showExtensionSettings() }; Button("刷新") { model.refreshDiagnostics() } }
                    Text(model.storageDiagnostic ?? "启用后，在下方配置的普通本地目录中打开 Finder 右键菜单。云盘位置的实际支持以系统与提供方验证结果为准。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                if model.authenticatedXPCBuild {
                    GroupBox("本机连接服务") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.localServiceStatus, systemImage: model.localServiceReady ? "checkmark.shield" : "exclamationmark.triangle")
                            HStack {
                                Button("启用或修复连接") { model.onRepairLocalService?() }
                                Button("停用并移除服务") { model.onStopLocalService?() }
                            }
                            Text("停用后 Finder 文件操作将不可用；设置会保留。删除应用前可先在这里移除服务。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if !model.recoveryTasks.isEmpty {
                    GroupBox("需要核对的文件") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("这些操作的文件状态尚未确认。请核对文件后再继续操作。").font(.caption)
                            ForEach(model.recoveryTasks) { task in
                                HStack { Text(task.title); Spacer(); Button("核对文件…") { model.onReviewTask?(task.id) } }
                            }
                        }.padding(8)
                    }
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
                        Text("不保存操作历史。组件诊断最多保留 7 天或 10 MiB，不逐项记录文件操作。临时通信状态在请求失效后自动清理；异常中断或无法确认安全的文件现场保留，供手动核对。").font(.caption).foregroundStyle(.secondary)
                        if let summary = model.retentionSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }
}
