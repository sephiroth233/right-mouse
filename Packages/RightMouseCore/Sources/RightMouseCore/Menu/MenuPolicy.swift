import Foundation

/// A filesystem-free menu plan shared by Finder and the settings preview.
public struct MenuEntry: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var enabled: Bool
    public var action: CommandAction?
    public var children: [MenuEntry]
    public init(id: String, title: String, enabled: Bool = true, action: CommandAction? = nil, children: [MenuEntry] = []) {
        self.id = id; self.title = title; self.enabled = enabled; self.action = action; self.children = children
    }
}

public enum MenuPolicy {
    public static func entries(configuration: AppConfiguration, context: ActionContext, pendingMove: PendingMoveSnapshot? = nil, now: Date = Date()) -> [MenuEntry] {
        entries(snapshot: MenuConfigurationSnapshot(configuration: configuration), context: context, pendingMove: pendingMove, now: now)
    }
    public static func entries(snapshot configuration: MenuConfigurationSnapshot, context: ActionContext, pendingMove: PendingMoveSnapshot? = nil, now: Date = Date()) -> [MenuEntry] {
        guard configuration.available else { return [] }
        let selection = !context.selection.isEmpty
        let validCount = context.selection.count <= 1024
        let parents = Set(context.selection.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        let destination = parents.count > 1 ? nil : context.container
        // Each new operation asks on collision; legacy saved defaults are ignored.
        let policy: ConflictPolicy = .ask
        var result: [MenuEntry] = []
        for configured in configuration.actions.enumerated().sorted(by: { $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order }).map(\.element) where configured.enabled {
            var entry: MenuEntry?
            switch configured.commandType {
            case "createFile":
                entry = MenuEntry(id: configured.id, title: configured.title, children: configuration.templates.map {
                    MenuEntry(id: "template.\($0.id)", title: $0.name, action: .createFile(templateID: $0.id, destination: destination, name: nil))
                })
            case "copyText":
                let pairs: [(CopyTextFormat, String)] = [(.path, "完整路径"), (.name, "文件名"), (.stem, "不含扩展名的名称"), (.shellPath, "终端转义路径")]
                entry = MenuEntry(id: configured.id, title: configured.title, children: pairs.map { format, title in
                    MenuEntry(id: "copy.\(format.rawValue)", title: title, enabled: validCount && (selection || (context.container != nil && (format == .path || format == .shellPath))), action: .copyText(format: format))
                })
            case "stageMove":
                if selection { entry = MenuEntry(id: configured.id, title: configured.title, enabled: validCount, action: .stageMove) }
            case "pasteMove":
                if let pendingMove, pendingMove.count > 0, pendingMove.expiresAt > now {
                    entry = MenuEntry(id: configured.id, title: "\(configured.title)（\(pendingMove.count) 项）", action: .pasteMove(pendingToken: pendingMove.token, destination: destination, conflictPolicy: policy))
                }
            case "copyTo", "moveTo":
                if selection {
                    let mode: CommandTransferMode = configured.commandType == "copyTo" ? .copy : .move
                    entry = MenuEntry(id: configured.id, title: configured.title + "…", enabled: validCount,
                                      action: .transfer(mode: mode, destination: nil, conflictPolicy: policy))
                }
            case "openFavorite": break // Retired; old configuration must not restore it.
            case "openWith":
                entry = MenuEntry(id: configured.id, title: configured.title, children: configuration.integrations.filter(\.enabled).map {
                    MenuEntry(id: "integration.\($0.id)", title: $0.name, enabled: validCount, action: .openWith(integrationID: $0.id, mode: $0.adapterType == "terminal" || !selection ? .directory : .files))
                })
            default: break
            }
            guard let entry else { continue }
            if entry.action == nil && entry.children.isEmpty { continue }
            if let group = configured.groupID, !group.isEmpty {
                if let index = result.firstIndex(where: { $0.id == "group.\(group)" }) { result[index].children.append(entry) }
                else { result.append(MenuEntry(id: "group.\(group)", title: group, children: [entry])) }
            } else { result.append(entry) }
        }
        let hidden = Set(configuration.hiddenEntryIDs ?? [])
        func visible(_ entries: [MenuEntry]) -> [MenuEntry] {
            entries.compactMap { original in
                guard !hidden.contains(original.id) else { return nil }
                var entry = original; entry.children = visible(entry.children)
                return entry.action != nil || !entry.children.isEmpty ? entry : nil
            }
        }
        result = visible(result)
        let selected = Set(configuration.topLevelEntryIDs ?? [])
        var promoted: [MenuEntry] = []
        func extract(_ entries: [MenuEntry]) -> [MenuEntry] {
            entries.compactMap { original in
                var entry = original
                entry.children = extract(entry.children)
                guard entry.action != nil || !entry.children.isEmpty else { return nil }
                if selected.contains(entry.id) {
                    entry.title = topLevelTitle(entry)
                    promoted.append(entry)
                    return nil
                }
                return entry
            }
        }
        result = extract(result)
        // Explicit selection order remains stable even when both a parent and
        // one of its descendants are promoted. Each command appears once.
        let order = configuration.topLevelEntryIDs ?? []
        promoted.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        if configuration.compactMenu, !result.isEmpty {
            result = [MenuEntry(id: "rightmouse", title: "RightMouse", children: result)]
        }
        result = promoted + result
        return validCount ? result : result.map(disabled)
    }

    public static func topLevelTitle(_ entry: MenuEntry) -> String {
        switch entry.action {
        case .createFile: return "新建 \(entry.title)"
        case .copyText: return "复制\(entry.title)"
        case let .openWith(id, _): return id == "terminal" ? "在终端中打开" : "使用 \(entry.title) 打开"
        case .transfer: return entry.title
        case .openFavorite: return "打开\(entry.title)"
        default: return entry.title
        }
    }

    private static func disabled(_ entry: MenuEntry) -> MenuEntry {
        var value = entry
        value.enabled = false
        value.children = value.children.map(disabled)
        return value
    }
}
