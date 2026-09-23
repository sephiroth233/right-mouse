import SwiftUI
import AppKit
import RightMouseCore

private struct EditorCategory: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let entries: [MenuEntry]
}
private enum EditorFilter: String, CaseIterable { case all = "全部", pinned = "一级菜单", hidden = "已隐藏" }

struct MenuSettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var search = ""
    @ViewState private var filter = EditorFilter.all
    @ViewState private var expanded: Set<String> = ["createFile"]
    @ViewState private var previewSelection = true
    @ViewState private var previewCut = false
    @ViewState private var previewPath: [String] = []
    @ViewState private var showingOrder = false
    @ViewState private var showingAdvanced = false
    @ViewState private var lastChanged: String?
    private var configuration: AppConfiguration {
        model.isLocalFinderMode && !model.authenticatedXPCBuild ? LocalMenuLayout(configuration: model.configuration).configuration : model.configuration
    }
    private var catalog: [MenuEntry] { MenuCustomization.catalog(configuration) }
    private var categories: [EditorCategory] {
        let definitions = [("createFile", "新建文件", "doc.badge.plus"), ("openWith", "打开方式", "square.grid.2x2"), ("copyText", "复制信息", "link")]
        var result: [EditorCategory] = definitions.compactMap { type, title, symbol in
            let ids = configuration.actions.filter { $0.commandType == type }.map(\.id)
            let rows = catalog.filter { ids.contains($0.id) }.flatMap(\.children)
            return rows.isEmpty ? nil : EditorCategory(id: type, title: title, symbol: symbol, entries: rows)
        }
        let fileIDs = configuration.actions.filter { ["stageMove", "pasteMove", "copyTo", "moveTo"].contains($0.commandType) }.map(\.id)
        let files = catalog.filter { fileIDs.contains($0.id) }
        if !files.isEmpty { result.append(.init(id: "files", title: "文件操作", symbol: "folder", entries: files)) }
        return result
    }
    private func matches(_ entry: MenuEntry, category: String) -> Bool {
        let placement = MenuCustomization.placement(entry.id, in: configuration)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (query.isEmpty || (entry.title + category).localizedCaseInsensitiveContains(query))
            && (filter == .all || (filter == .pinned && placement == .topLevel) || (filter == .hidden && placement == .hidden))
    }
    private var preview: [MenuEntry] {
        var context = MenuCustomization.context
        if !previewSelection { context = ActionContext(entryPoint: .container, container: context.container, selection: []) }
        return MenuPolicy.entries(configuration: configuration, context: context,
            pendingMove: previewCut ? PendingMoveSnapshot(token: UUID(), count: 1, expiresAt: .distantFuture) : nil)
    }
    private var previewLevel: [MenuEntry] {
        var entries = preview
        for id in previewPath { guard let parent = entries.first(where: { $0.id == id }) else { return preview }; entries = parent.children }
        return entries
    }
    private func setPlacement(_ value: MenuPlacement, entries: [MenuEntry]) {
        if model.save({ MenuCustomization.set(value, for: entries.map(\.id), in: &$0) }) {
            previewPath = []; lastChanged = entries.first?.id
        }
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 14) {
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
                previewPanel.frame(width: max(218, geometry.size.width * 0.40)).frame(maxHeight: .infinity)
            }
        }.padding(.horizontal, 18).padding(.bottom, 18)
            .sheet(isPresented: $showingOrder) { orderSheet }
            .sheet(isPresented: $showingAdvanced) { advancedSheet }
            .onChange(of: previewSelection) { previewPath = [] }
            .onChange(of: previewCut) { previewPath = [] }
    }
    private var editor: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { filterPicker; searchField.frame(minWidth: 110) }
                VStack(spacing: 8) { filterPicker; searchField }
            }
            HStack { Text("操作"); Spacer(); Text("显示位置").frame(width: 106, alignment: .leading) }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(categories) { category in
                        let rows = category.entries.filter { matches($0, category: category.title) }
                        if !rows.isEmpty { categorySection(category, rows: rows) }
                    }
                    if !categories.contains(where: { category in category.entries.contains { matches($0, category: category.title) } }) {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                            Text("没有匹配的操作").font(.headline)
                            Button("清除筛选") { search = ""; filter = .all }
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                }
            }.scrollIndicators(.visible)
            HStack {
                Button("一级菜单排序…") { showingOrder = true }.disabled(model.isReadOnly)
                Spacer(minLength: 4)
                Button { showingAdvanced = true } label: { HStack(spacing: 3) { Text("高级设置"); Image(systemName: "chevron.right").font(.caption) } }.buttonStyle(.plain).foregroundStyle(.tint)
            }.font(.callout)
            Text("更改自动保存").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(12).background(.background.opacity(0.84), in: RoundedRectangle(cornerRadius: 16))
    }
    private var filterPicker: some View {
        Picker("筛选操作", selection: $filter) { ForEach(EditorFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
    }
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索操作", text: $search).textFieldStyle(.plain).accessibilityLabel("搜索菜单操作")
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
        }.padding(7).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func categorySection(_ category: EditorCategory, rows: [MenuEntry]) -> some View {
        let isExpanded = expanded.contains(category.id) || !search.isEmpty || filter != .all
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if expanded.contains(category.id) { expanded.remove(category.id) } else { expanded.insert(category.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 10)
                        Image(systemName: category.symbol).font(.system(size: 16)).foregroundStyle(category.id == "createFile" ? Color.accentColor : .primary).frame(width: 20)
                        Text(category.title).font(.system(size: 13, weight: .semibold))
                        Text("\(rows.count) 项").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(isExpanded ? "折叠" : "展开")\(category.title)")
                Menu {
                    ForEach(MenuPlacement.allCases, id: \.self) { placement in
                        Button(placement == .hidden ? "隐藏全部" : "全部放到\(placement.rawValue)") { setPlacement(placement, entries: category.entries) }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isReadOnly)
                    .accessibilityLabel("\(category.title)批量设置")
            }.padding(.horizontal, 6).frame(height: 36)
            if isExpanded { ForEach(rows) { entry in placementRow(entry) } }
            Divider()
        }
    }
    private func placementRow(_ entry: MenuEntry) -> some View {
        let placement = MenuCustomization.placement(entry.id, in: configuration)
        return HStack(spacing: 8) {
            MenuEntryIcon(entry: entry, integrations: model.configuration.integrations)
            Text(entry.title).font(.system(size: 13)).lineLimit(1).help(entry.title)
                .foregroundStyle(placement == .hidden ? .secondary : .primary)
            Spacer(minLength: 4)
            Picker("\(entry.title)显示位置", selection: Binding(get: { placement }, set: { setPlacement($0, entries: [entry]) })) {
                ForEach(MenuPlacement.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 106).controlSize(.regular)
                .tint(placement == .topLevel ? .accentColor : .secondary).disabled(model.isReadOnly)
        }.padding(.leading, 24).padding(.trailing, 6).frame(height: 34)
            .background(lastChanged == entry.id ? Color.accentColor.opacity(0.055) : .clear)
            .overlay(alignment: .bottom) { Divider().padding(.leading, 24) }
    }
    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("菜单预览").font(.headline)
            Picker("预览场景", selection: $previewSelection) { Text("选中文件").tag(true); Text("空白处").tag(false) }.pickerStyle(.segmented).labelsHidden()
            if !previewPath.isEmpty {
                Button { previewPath.removeLast() } label: { Label("返回上级", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.tint)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if previewLevel.isEmpty { Text("此场景没有可见操作").foregroundStyle(.secondary).padding(12) }
                    ForEach(previewLevel) { entry in
                        Button {
                            if !entry.children.isEmpty { previewPath.append(entry.id) }
                        } label: {
                            HStack(spacing: 9) {
                                MenuEntryIcon(entry: entry, integrations: model.configuration.integrations)
                                Text(entry.title).font(.system(size: 12.5)).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if !entry.children.isEmpty { Image(systemName: "chevron.right").font(.caption) }
                            }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(lastChanged == entry.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(!entry.enabled)
                            .accessibilityLabel(entry.children.isEmpty ? "预览：\(entry.title)" : "展开预览：\(entry.title)")
                    }
                }.padding(5).background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.separator.opacity(0.45), lineWidth: 0.5))
            }.scrollIndicators(.visible).frame(height: min(CGFloat(previewLevel.count) * 42 + 12, 320))
            Text("点击箭头查看子菜单\n菜单位置以 Finder 实际显示为准。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }.padding(14).background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }
    private var orderingEntries: [MenuEntry] {
        MenuPolicy.entries(configuration: configuration, context: MenuCustomization.context,
            pendingMove: PendingMoveSnapshot(token: UUID(), count: 1, expiresAt: .distantFuture)).filter { $0.id != "rightmouse" }
    }
    private func reorder(_ from: IndexSet, to: Int) {
        var ids = orderingEntries.map(\.id); ids.move(fromOffsets: from, toOffset: to)
        model.save { value in
            value.compactMenu = true
            value.topLevelEntryIDs = ids + value.topLevelEntryIDs.filter { !ids.contains($0) }
        }
    }
    private var orderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("一级菜单顺序").font(.title2.bold())
            Text("拖动排列，或使用上移、下移按钮。").foregroundStyle(.secondary)
            List {
                ForEach(Array(orderingEntries.enumerated()), id: \.element.id) { index, entry in
                    HStack { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary); MenuEntryIcon(entry: entry, integrations: configuration.integrations); Text(entry.title); Spacer(); MoveControls(index: index, count: orderingEntries.count) { delta in reorder(IndexSet(integer: index), to: delta < 0 ? index - 1 : index + 2) } }.padding(.vertical, 5)
                }.onMove(perform: reorder)
            }.overlay { if orderingEntries.isEmpty { Text("先将常用操作设为一级菜单。").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("完成") { showingOrder = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 450, height: 400)
    }
    private var advancedSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("高级设置").font(.title2.bold())
            Toggle("预览中模拟已剪切文件", isOn: $previewCut)
            Text("只影响右侧预览，不读取或修改剪贴板。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("恢复默认菜单布局").font(.headline)
            Text("显示全部操作并收进 RightMouse 子菜单，清除置顶与自定义分组；保留模板、应用和其他设置。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("恢复默认布局") {
                model.save { value in
                    value.compactMenu = true; value.topLevelEntryIDs = []; value.hiddenEntryIDs = []
                    for i in value.actions.indices { value.actions[i].enabled = true; value.actions[i].groupID = nil }
                    for i in value.integrations.indices { value.integrations[i].enabled = true }
                }
                previewPath = []; showingAdvanced = false
            }.disabled(model.isReadOnly)
            HStack { Spacer(); Button("完成") { showingAdvanced = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 420)
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
                        Image(systemName: MenuIcon.template(template.id)).font(.title2).foregroundStyle(.blue).frame(width: 30).accessibilityHidden(true)
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
                        ApplicationIcon(integration: app)
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
