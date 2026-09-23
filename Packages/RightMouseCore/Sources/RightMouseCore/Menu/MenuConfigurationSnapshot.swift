import Foundation

/// Finder receives display metadata and stable reference IDs, never authority
/// (bookmarks), template bytes, application paths, or operation history.
public struct MenuLocation: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let order: Int
}
public struct MenuTemplate: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
}
public struct MenuIntegration: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let adapterType: String
    public let enabled: Bool
}
public struct MenuConfigurationSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let available: Bool
    public let compactMenu: Bool
    // Optional on the wire so snapshots from older schema-1 builds still load.
    public let topLevelEntryIDs: [String]?
    public let conflictPolicy: String
    public let actions: [ConfiguredAction]
    public let favorites: [MenuLocation]
    public let watchedLocations: [MenuLocation]
    public let recentDestinations: [MenuLocation]
    public let integrations: [MenuIntegration]
    public let templates: [MenuTemplate]

    public init(configuration: AppConfiguration, available: Bool = true) {
        schemaVersion = 1; revision = configuration.revision; self.available = available
        compactMenu = configuration.compactMenu; conflictPolicy = configuration.conflictPolicy
        topLevelEntryIDs = configuration.topLevelEntryIDs
        actions = available ? configuration.actions : []
        favorites = available ? configuration.favorites.map { .init(id: $0.id, name: $0.name, path: $0.path, order: $0.order) } : []
        watchedLocations = available ? configuration.watchedLocations.map { .init(id: $0.id, name: $0.name, path: $0.path, order: $0.order) } : []
        recentDestinations = available ? configuration.recentDestinations.enumerated().map { .init(id: $0.element.id, name: $0.element.name, path: $0.element.path, order: $0.offset) } : []
        integrations = available ? configuration.integrations.map { .init(id: $0.id, name: $0.name, adapterType: $0.adapterType, enabled: $0.enabled) } : []
        templates = available ? configuration.templates.map { .init(id: $0.id, name: $0.name) } : []
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ConfigurationError.futureVersion(schemaVersion) }
        let promoted = topLevelEntryIDs ?? []
        guard promoted.count <= 100, Set(promoted).count == promoted.count,
              promoted.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 }) else { throw ConfigurationError.invalid("一级菜单快照无效。") }
        let commands: Set<String> = ["createFile", "copyText", "stageMove", "pasteMove", "copyTo", "moveTo", "openFavorite", "openWith"]
        guard revision >= 0, [actions.count, favorites.count, watchedLocations.count, integrations.count, templates.count].allSatisfy({ $0 <= 100 }),
              recentDestinations.count <= 10, ["ask", "skip", "keepBoth"].contains(conflictPolicy),
              actions.allSatisfy({ commands.contains($0.commandType) }),
              integrations.allSatisfy({ ["urls", "terminal", "vscode"].contains($0.adapterType) }),
              Set(actions.map(\.id)).count == actions.count, Set(templates.map(\.id)).count == templates.count,
              Set(integrations.map(\.id)).count == integrations.count else { throw ConfigurationError.invalid("菜单快照无效。") }
        for locations in [favorites, watchedLocations, recentDestinations] {
            guard Set(locations.map(\.id)).count == locations.count,
                  locations.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") && !$0.name.isEmpty }) else { throw ConfigurationError.invalid("菜单目录引用无效。") }
        }
    }
}

public struct MenuSnapshotStore {
    public static let maximumBytes = ConfigurationStore.maximumBytes
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("menu.json") }
    public init(directory: URL) { self.directory = directory }
    public func publish(_ configuration: AppConfiguration, available: Bool = true) throws {
        try configuration.validate()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let previous = try PrivateFileIO.read(fileURL, maximumBytes: Self.maximumBytes)
            if let object = (try? JSONSerialization.jsonObject(with: previous)) as? [String: Any],
               let version = object["schemaVersion"] as? Int, version != 1 {
                throw ConfigurationError.futureVersion(version)
            }
        }
        let snapshot = MenuConfigurationSnapshot(configuration: configuration, available: available)
        try snapshot.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw ConfigurationError.invalid("菜单快照超过容量上限，旧快照已保留。") }
        try PrivateFileIO.write(data, to: fileURL)
    }
    public func load() throws -> MenuConfigurationSnapshot {
        let data = try PrivateFileIO.read(fileURL, maximumBytes: Self.maximumBytes)
        let value = try JSONDecoder().decode(MenuConfigurationSnapshot.self, from: data)
        try value.validate()
        return value
    }
}
