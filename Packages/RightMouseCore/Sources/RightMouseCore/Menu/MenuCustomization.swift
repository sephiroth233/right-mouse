import Foundation

public enum MenuPlacement: String, CaseIterable, Sendable {
    case topLevel = "一级菜单", submenu = "子菜单", hidden = "隐藏"
}

/// Shared editing semantics: the UI and Finder use the same stable entry IDs.
public enum MenuCustomization {
    public static let context = ActionContext(entryPoint: .items,
        container: FileReference(url: URL(fileURLWithPath: "/preview", isDirectory: true), kindHint: .directory),
        selection: [FileReference(url: URL(fileURLWithPath: "/preview/file.txt"), kindHint: .file)])
    public static func catalog(_ configuration: AppConfiguration) -> [MenuEntry] {
        var value = configuration
        value.compactMenu = false; value.topLevelEntryIDs = []; value.hiddenEntryIDs = []
        for i in value.actions.indices { value.actions[i].enabled = true; value.actions[i].groupID = nil }
        for i in value.integrations.indices { value.integrations[i].enabled = true }
        return MenuPolicy.entries(configuration: value, context: context,
            pendingMove: PendingMoveSnapshot(token: UUID(), count: 1, expiresAt: .distantFuture))
    }
    public static func placement(_ id: String, in configuration: AppConfiguration) -> MenuPlacement {
        let parent = catalog(configuration).first { $0.id == id || $0.children.contains { $0.id == id } }
        if configuration.hiddenEntryIDs.contains(id) || parent.map({ configuration.hiddenEntryIDs.contains($0.id) }) == true
            || parent.map({ p in configuration.actions.contains { $0.id == p.id && !$0.enabled } }) == true { return .hidden }
        if id.hasPrefix("integration."), configuration.integrations.contains(where: { "integration." + $0.id == id && !$0.enabled }) { return .hidden }
        if configuration.topLevelEntryIDs.contains(id) { return .topLevel }
        if parent?.id == id, !configuration.compactMenu,
           configuration.actions.first(where: { $0.id == id })?.groupID == nil { return .topLevel }
        return .submenu
    }
    public static func set(_ placement: MenuPlacement, for ids: [String], in configuration: inout AppConfiguration) {
        let catalog = catalog(configuration)
        // Preserve existing root commands when converting a flat legacy layout.
        if !configuration.compactMenu {
            let roots = MenuPolicy.entries(configuration: configuration, context: context,
                pendingMove: PendingMoveSnapshot(token: UUID(), count: 1, expiresAt: .distantFuture))
            for entry in roots where !configuration.topLevelEntryIDs.contains(entry.id) { configuration.topLevelEntryIDs.append(entry.id) }
            configuration.compactMenu = true
        }
        for id in ids {
            guard let parent = catalog.first(where: { $0.id == id || $0.children.contains { $0.id == id } }) else { continue }
            if placement != .hidden, let index = configuration.actions.firstIndex(where: { $0.id == parent.id }) {
                if !configuration.actions[index].enabled || configuration.hiddenEntryIDs.contains(parent.id) {
                    for sibling in parent.children where !configuration.hiddenEntryIDs.contains(sibling.id) { configuration.hiddenEntryIDs.append(sibling.id) }
                    configuration.actions[index].enabled = true
                    configuration.hiddenEntryIDs.removeAll { $0 == parent.id }
                }
                if let appIndex = configuration.integrations.firstIndex(where: { "integration." + $0.id == id }) {
                    configuration.integrations[appIndex].enabled = true
                }
            }
            configuration.hiddenEntryIDs.removeAll { $0 == id }
            configuration.topLevelEntryIDs.removeAll { $0 == id }
            if placement == .hidden { configuration.hiddenEntryIDs.append(id) }
            if placement == .topLevel { configuration.topLevelEntryIDs.append(id) }
        }
    }
    public static func entryID(for action: CommandAction, configuration: AppConfiguration) -> String? {
        switch action {
        case .createFile(let id, _, _): return "template." + id
        case .openWith(let id, _): return "integration." + id
        case .copyText(let format): return "copy." + format.rawValue
        default:
            let type: String
            if case .transfer(let mode, _, _) = action { type = mode == .copy ? "copyTo" : "moveTo" }
            else { type = action.type }
            return configuration.actions.first { $0.commandType == type }?.id
        }
    }
}
