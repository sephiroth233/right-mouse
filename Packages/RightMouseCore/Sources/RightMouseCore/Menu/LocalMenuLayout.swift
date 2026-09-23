import Foundation

/// Public, authority-free presentation preferences for ad-hoc Finder builds.
/// Notifications may be spoofed: accepting one must never perform an operation,
/// add a command, read a path, or grant filesystem access.
public struct LocalMenuLayout: Codable, Equatable, Sendable {
    public static let changed = Notification.Name("cn.rightmouse.menu-layout.changed.v1")
    public static let requested = Notification.Name("cn.rightmouse.menu-layout.requested.v1")
    public static let cacheKey = "RightMouseLocalMenuLayout.v1"
    public static let maximumBytes = 16 * 1024
    public var version = 1
    public var compactMenu: Bool
    public var topLevelEntryIDs: [String]
    public var hiddenEntryIDs: [String]?

    public init(configuration: AppConfiguration) {
        compactMenu = configuration.compactMenu
        hiddenEntryIDs = configuration.hiddenEntryIDs.filter { Self.allowedIDs.contains($0) }
        topLevelEntryIDs = configuration.topLevelEntryIDs.filter { Self.allowedIDs.contains($0) }
    }
    public static var baseConfiguration: AppConfiguration {
        var value = AppConfiguration()
        value.compactMenu = true
        value.actions.removeAll { ["stageMove", "pasteMove", "openFavorite"].contains($0.commandType) }
        value.templates.removeAll { !LocalFinderRequest.allowedTemplateIDs.contains($0.id) }
        return value
    }
    private static let allowedIDs: Set<String> = {
        let defaults = baseConfiguration
        return Set(defaults.actions.map(\.id)
            + defaults.templates.map { "template." + $0.id }
            + defaults.integrations.map { "integration." + $0.id }
            + ["copy.path", "copy.name", "copy.stem", "copy.shellPath", "copy.choose", "move.choose"])
    }()
    public var configuration: AppConfiguration {
        var value = Self.baseConfiguration
        value.compactMenu = compactMenu
        value.topLevelEntryIDs = topLevelEntryIDs
        value.hiddenEntryIDs = hiddenEntryIDs ?? []
        return value
    }
    public func encoded() throws -> String {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes, let string = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.invalid("菜单层级通知过大。")
        }
        return string
    }
    public static func decode(_ string: String) throws -> Self {
        guard string.utf8.count <= maximumBytes else { throw ConfigurationError.invalid("菜单层级通知过大。") }
        let data = Data(string.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(["version", "compactMenu", "topLevelEntryIDs"]).isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: Set(["version", "compactMenu", "topLevelEntryIDs", "hiddenEntryIDs"])) else {
            throw ConfigurationError.invalid("菜单层级通知字段无效。")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    private func validate() throws {
        guard (hiddenEntryIDs ?? []).count <= 100, Set(hiddenEntryIDs ?? []).count == (hiddenEntryIDs ?? []).count, (hiddenEntryIDs ?? []).allSatisfy({ Self.allowedIDs.contains($0) }), version == 1, topLevelEntryIDs.count <= 100,
              Set(topLevelEntryIDs).count == topLevelEntryIDs.count,
              topLevelEntryIDs.allSatisfy({ Self.allowedIDs.contains($0) }) else {
            throw ConfigurationError.invalid("菜单层级通知无效。")
        }
    }
}
