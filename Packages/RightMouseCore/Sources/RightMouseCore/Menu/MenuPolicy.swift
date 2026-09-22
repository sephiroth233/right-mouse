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
        let selection = !context.selection.isEmpty
        let validCount = context.selection.count <= 1024
        let parents = Set(context.selection.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        let destination = parents.count > 1 ? nil : context.container
        let policy = ConflictPolicy(rawValue: configuration.conflictPolicy) ?? .ask
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
                    var children = configuration.favorites.sorted { $0.order < $1.order }.map {
                        MenuEntry(id: "\(mode.rawValue).\($0.id)", title: $0.name, enabled: validCount, action: .transfer(mode: mode, destination: FileReference(url: URL(fileURLWithPath: $0.path, isDirectory: true), kindHint: .directory), conflictPolicy: policy))
                    }
                    children.append(MenuEntry(id: "\(mode.rawValue).choose", title: "选择目录…", enabled: validCount, action: .transfer(mode: mode, destination: nil, conflictPolicy: policy)))
                    entry = MenuEntry(id: configured.id, title: configured.title, children: children)
                }
            case "openFavorite":
                if !configuration.favorites.isEmpty {
                    entry = MenuEntry(id: configured.id, title: configured.title, children: configuration.favorites.sorted { $0.order < $1.order }.map {
                        MenuEntry(id: "favorite.\($0.id)", title: $0.name, action: .openFavorite(favoriteID: $0.id))
                    })
                }
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
        if !validCount { result = result.map(disabled) }
        if configuration.compactMenu { return [MenuEntry(id: "rightmouse", title: "RightMouse", children: result)] }
        return result
    }

    private static func disabled(_ entry: MenuEntry) -> MenuEntry {
        var value = entry
        value.enabled = false
        value.children = value.children.map(disabled)
        return value
    }
}
