import SwiftUI
import AppKit
import RightMouseCore

struct MenuSettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var previewSelection = true
    private var preview: [MenuEntry] {
        let folder = FileReference(url: URL(fileURLWithPath: "/示例/项目", isDirectory: true), kindHint: .directory)
        let file = FileReference(url: URL(fileURLWithPath: "/示例/项目/说明.md"), kindHint: .file)
        return MenuPolicy.entries(configuration: model.configuration, context: ActionContext(entryPoint: previewSelection ? .items : .container, container: folder, selection: previewSelection ? [file] : []))
    }
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("紧凑模式", isOn: model.binding(\.compactMenu))
                Text("用箭头或拖动调整顺序；分组名称相同的项目会进入同一子菜单。").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(Array(model.configuration.actions.enumerated()), id: \.element.id) { index, action in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(action.title, isOn: Binding(get: { action.enabled }, set: { enabled in model.save { $0.actions[index].enabled = enabled } }))
                                Spacer()
                                MoveControls(index: index, count: model.configuration.actions.count) { offset in move(index, offset) }
                            }
                            TextField("分组（留空表示直接显示）", text: Binding(get: { action.groupID ?? "" }, set: { group in model.save { $0.actions[index].groupID = group.isEmpty ? nil : group } }))
                                .textFieldStyle(.roundedBorder).font(.caption).accessibilityLabel("\(action.title)分组")
                        }.padding(.vertical, 5)
                    }.onMove { source, target in model.save { value in value.actions.move(fromOffsets: source, toOffset: target); normalize(&value.actions) } }
                }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
            }.frame(maxWidth: .infinity).disabled(model.isReadOnly)
            VStack(alignment: .leading, spacing: 12) {
                Text("菜单预览").font(.headline)
                Picker("上下文", selection: $previewSelection) { Text("选中文件").tag(true); Text("空白处").tag(false) }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if preview.isEmpty { Text("没有可见操作").foregroundStyle(.secondary) }
                        ForEach(preview) { entry in MenuPreviewRow(entry: entry) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.rightMouseGlass(radius: 16)
                Text("与 Finder 共用菜单规则；没有待移动文件时不显示粘贴。系统菜单中的最终位置由 Finder 决定。").font(.caption).foregroundStyle(.secondary)
            }.frame(minWidth: 205, idealWidth: 225, maxWidth: 245)
        }.padding(.horizontal, 28).padding(.bottom, 24)
    }
    private func move(_ index: Int, _ delta: Int) {
        model.save { value in value.actions.swapAt(index, index + delta); normalize(&value.actions) }
    }
    private func normalize(_ actions: inout [ConfiguredAction]) { for index in actions.indices { actions[index].order = index } }
}

private struct MenuPreviewRow: View {
    let entry: MenuEntry
    var depth: Int = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(entry.title); Spacer(); if !entry.children.isEmpty { Image(systemName: "chevron.right").font(.caption2) } }
                .foregroundStyle(entry.enabled ? .primary : .secondary)
                .font(depth == 0 ? .body : .caption)
            if !entry.children.isEmpty {
                ForEach(entry.children) { child in
                    AnyView(MenuPreviewRow(entry: child, depth: depth + 1)).padding(.leading, 12)
                }
            }
        }.padding(.vertical, 3)
    }
}

struct MoveControls: View {
    let index: Int
    let count: Int
    var move: (Int) -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel("上移")
            Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index >= count - 1).accessibilityLabel("下移")
        }.buttonStyle(.borderless)
    }
}

struct TemplateSettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var editing: FileTemplate?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("\(model.configuration.templates.count) / 100 个模板").foregroundStyle(.secondary); Spacer(); Button("恢复内置模板") { model.save { value in for template in FileTemplate.builtIns where !value.templates.contains(where: { $0.id == template.id }) { value.templates.append(template) } } }; Button("导入模板…") { model.importTemplate() }.buttonStyle(.borderedProminent) }
            List {
                ForEach(Array(model.configuration.templates.enumerated()), id: \.element.id) { index, template in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text").font(.title2).foregroundStyle(.blue).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name).font(.headline)
                            Text(template.filename + (template.usesVariables ? " · 文本变量" : "") + (template.isBuiltIn ? " · 内置" : " · 已导入")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MoveControls(index: index, count: model.configuration.templates.count) { delta in model.save { $0.templates.swapAt(index, index + delta) } }
                        Button("编辑") { editing = template }.accessibilityLabel("编辑模板 \(template.name)")
                        Button { model.removeTemplate(template) } label: { Image(systemName: "trash") }.accessibilityLabel("删除模板 \(template.name)")
                    }.padding(.vertical, 8).buttonStyle(.borderless).accessibilityElement(children: .contain)
                }.onMove { source, target in model.save { $0.templates.move(fromOffsets: source, toOffset: target) } }
            }.listStyle(.inset)
            Text("支持普通文件，包括真实办公文档。符号链接和包目录不可导入。删除模板只移除应用保存的副本。").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 28).padding(.bottom, 24).disabled(model.isReadOnly)
            .sheet(item: $editing) { template in TemplateEditor(model: model, template: template) }
    }
}

private struct TemplateEditor: View {
    @ObservedObject var model: AppModel
    @ViewState var template: FileTemplate
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑模板").font(.title2.weight(.semibold))
            Form {
                TextField("显示名称", text: $template.name)
                TextField("默认文件名", text: $template.filename)
                Toggle("启用 UTF-8 文本变量", isOn: $template.usesVariables)
                Text("仅替换 {{date}} 和 {{filename}}；二进制模板请关闭此选项。变量不会执行代码。日期为创建日期，文件名包含重名序号。").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { if model.updateTemplate(template) { dismiss() } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 440)
    }
}

struct LocationSettingsView: View {
    @ObservedObject var model: AppModel
    let watched: Bool
    @ViewState private var editing: SavedLocation?
    private var locations: [SavedLocation] { watched ? model.configuration.watchedLocations : model.configuration.favorites }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("\(locations.count) / 100 个目录").font(.caption).foregroundStyle(.secondary); Spacer(); Button("添加目录…") { model.chooseLocation(watched: watched) }.buttonStyle(.borderedProminent) }
            if locations.isEmpty {
                VStack(spacing: 10) { Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.secondary); Text(watched ? "选择需要显示右键菜单的目录" : "收藏第一个常用目录").font(.headline); Text("删除这里的记录不会删除磁盘上的文件夹。").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).padding(30).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(locations.enumerated()), id: \.element.id) { index, location in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) { Text(location.name).font(.headline); Text(location.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle); if (try? location.resolve()) == nil { Text("书签不可用，请重新选择目录").font(.caption).foregroundStyle(.orange) } }
                            Spacer()
                            MoveControls(index: index, count: locations.count) { delta in modify { $0.swapAt(index, index + delta) } }
                            Menu {
                                Button("在 Finder 中打开") { model.openLocation(location) }
                                Button("改名") { editing = location }
                                Button("重新选择…") { model.chooseLocation(watched: watched, replacing: location.id) }
                                Divider()
                                Button("移除", role: .destructive) { modify { $0.removeAll { $0.id == location.id } } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).frame(width: 26).accessibilityLabel("\(location.name)选项")
                        }.padding(12)
                        if index < locations.count - 1 { Divider() }
                    }
                }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }
            if !watched { Spacer(minLength: 0) }
        }.padding(.horizontal, watched ? 0 : 28).padding(.bottom, watched ? 0 : 24).disabled(model.isReadOnly)
            .sheet(item: $editing) { location in LocationNameEditor(location: location) { updated in modify { if let index = $0.firstIndex(where: { $0.id == updated.id }) { $0[index].name = updated.name } } } }
    }
    private func modify(_ change: (inout [SavedLocation]) -> Void) {
        model.save { config in
            var list = watched ? config.watchedLocations : config.favorites
            change(&list)
            for index in list.indices { list[index].order = index }
            if watched { config.watchedLocations = list } else { config.favorites = list }
        }
    }
}

private struct LocationNameEditor: View {
    @ViewState var location: SavedLocation
    var save: (SavedLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("目录显示名称").font(.title2)
            TextField("名称", text: $location.name).textFieldStyle(.roundedBorder)
            Text("这里只修改菜单中的名称，不重命名磁盘目录。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { save(location); dismiss() }.disabled(location.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 380)
    }
}

struct ApplicationSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("启用后显示在“打开方式”菜单中。").foregroundStyle(.secondary); Spacer(); Button("添加应用…") { model.addApplication() }.buttonStyle(.borderedProminent) }
            List {
                ForEach(Array(model.configuration.integrations.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 12) {
                        Image(systemName: app.adapterType == "terminal" ? "terminal" : "app").font(.title2).foregroundStyle(.blue).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(app.name, isOn: Binding(get: { app.enabled }, set: { enabled in model.save { $0.integrations[index].enabled = enabled } }))
                            Text(app.adapterType == "terminal" ? "在当前目录启动终端" : "接收选中文件或文件夹").font(.caption).foregroundStyle(.secondary)
                            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) == nil && app.applicationPath == nil { Text("尚未找到此应用，可用“添加应用”定位。").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        MoveControls(index: index, count: model.configuration.integrations.count) { delta in model.save { $0.integrations.swapAt(index, index + delta) } }
                        Button { model.save { $0.integrations.removeAll { $0.id == app.id } } } label: { Image(systemName: "trash") }.accessibilityLabel("移除 \(app.name)")
                    }.padding(.vertical, 8).buttonStyle(.borderless).accessibilityElement(children: .contain)
                }
            }.listStyle(.inset)
            Text("自定义应用通过 macOS 的标准文件打开接口接收 URL；是否支持该文件类型取决于应用自身。").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 28).padding(.bottom, 24).disabled(model.isReadOnly)
    }
}
