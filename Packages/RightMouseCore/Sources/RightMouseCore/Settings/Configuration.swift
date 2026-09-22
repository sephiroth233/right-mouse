import Foundation

public struct ConfiguredAction: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var commandType: String
    public var title: String
    public var enabled: Bool
    public var order: Int
    public var groupID: String?
    public init(id: String, commandType: String, title: String, enabled: Bool = true, order: Int = 0, groupID: String? = nil) {
        self.id = id; self.commandType = commandType; self.title = title; self.enabled = enabled; self.order = order; self.groupID = groupID
    }
}

public struct SavedLocation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmarkData: Data?
    public var order: Int
    public init(id: UUID = UUID(), name: String, path: String, bookmarkData: Data? = nil, order: Int = 0) {
        self.id = id; self.name = name; self.path = path; self.bookmarkData = bookmarkData; self.order = order
    }
    public func resolve() throws -> URL {
        if let data = bookmarkData {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw ConfigurationError.invalid("目录书签已失效，请重新选择目录。") }
            return url
        }
        throw ConfigurationError.invalid("目录没有有效书签，请重新选择目录。")
    }
}

public struct AppIntegration: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    public var applicationPath: String?
    public var adapterType: String
    public var enabled: Bool
    public init(id: String, name: String, bundleID: String, applicationPath: String? = nil, adapterType: String = "urls", enabled: Bool = true) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.applicationPath = applicationPath; self.adapterType = adapterType; self.enabled = enabled
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var revision: Int = 0
    public var compactMenu = false
    public var launchAtLogin = false
    public var revealCreatedFile = true
    public var conflictPolicy = "ask"
    public var actions: [ConfiguredAction]
    public var favorites: [SavedLocation] = []
    public var watchedLocations: [SavedLocation] = []
    public var integrations: [AppIntegration]
    public var templates: [FileTemplate]
    public init() {
        actions = [
            .init(id: "createFile", commandType: "createFile", title: "新建文件", order: 0),
            .init(id: "copyText", commandType: "copyText", title: "复制路径与名称", order: 1),
            .init(id: "stageMove", commandType: "stageMove", title: "剪切文件", order: 2),
            .init(id: "pasteMove", commandType: "pasteMove", title: "粘贴待移动文件", order: 3),
            .init(id: "copyTo", commandType: "copyTo", title: "复制到", order: 4),
            .init(id: "moveTo", commandType: "moveTo", title: "移动到", order: 5),
            .init(id: "openFavorite", commandType: "openFavorite", title: "常用目录", order: 6),
            .init(id: "openWith", commandType: "openWith", title: "打开方式", order: 7)
        ]
        integrations = [
            .init(id: "terminal", name: "终端", bundleID: "com.apple.Terminal", adapterType: "terminal"),
            .init(id: "vscode", name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", adapterType: "vscode")
        ]
        templates = FileTemplate.builtIns
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ConfigurationError.futureVersion(schemaVersion) }
        guard revision >= 0, [actions.count, favorites.count, watchedLocations.count, integrations.count, templates.count].allSatisfy({ $0 <= 100 }) else { throw ConfigurationError.invalid("配置项数量不能超过 100。") }
        guard Set(actions.map(\.id)).count == actions.count, Set(favorites.map(\.id)).count == favorites.count,
              Set(watchedLocations.map(\.id)).count == watchedLocations.count, Set(integrations.map(\.id)).count == integrations.count,
              Set(templates.map(\.id)).count == templates.count else { throw ConfigurationError.invalid("配置包含重复标识。") }
        let commands: Set<String> = ["createFile", "copyText", "stageMove", "pasteMove", "copyTo", "moveTo", "openFavorite", "openWith"]
        guard actions.allSatisfy({ commands.contains($0.commandType) }), ["ask", "skip", "keepBoth"].contains(conflictPolicy) else { throw ConfigurationError.invalid("配置包含未知操作。") }
        for template in templates { try template.validate() }
        for location in favorites + watchedLocations {
            guard location.path.hasPrefix("/"), !location.path.contains("\0"), !location.name.isEmpty else { throw ConfigurationError.invalid("目录配置无效。") }
        }
        guard integrations.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && !$0.bundleID.isEmpty && ["urls", "terminal", "vscode"].contains($0.adapterType) }) else { throw ConfigurationError.invalid("打开方式配置无效。") }
    }
}

public enum ConfigurationError: LocalizedError {
    case futureVersion(Int), invalid(String)
    public var errorDescription: String? {
        switch self {
        case .futureVersion(let version): return "配置版本 \(version) 不受此版本支持，已保留原文件并禁止写入。"
        case .invalid(let reason): return reason
        }
    }
}

/// Host-owned store. A future schema is never replaced with defaults.
public final class ConfigurationStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("configuration.json") }
    public private(set) var lastWarning: String?
    private let lock = NSRecursiveLock()
    public init(directory: URL) { self.directory = directory }
    public func load(readOnly: Bool = false) throws -> AppConfiguration {
        lock.lock(); defer { lock.unlock() }
        lastWarning = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppConfiguration() }
        let data = try PrivateFileIO.read(fileURL, maximumBytes: 8 * 1024 * 1024)
        // Probe the version before decoding other fields: newer formats may remove them.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["schemaVersion"] as? Int, version != 1 {
            throw ConfigurationError.futureVersion(version)
        }
        do {
            let value = try JSONDecoder().decode(AppConfiguration.self, from: data)
            try value.validate()
            return value
        } catch {
            let backup = directory.appendingPathComponent("configuration.corrupt.\(UUID().uuidString).json")
            if readOnly { lastWarning = "配置损坏，使用安全默认；请打开宿主应用修复。" }
            else {
                try PrivateFileIO.write(data, to: backup, replace: false)
                lastWarning = "配置损坏，已备份为 \(backup.lastPathComponent)，恢复安全默认。"
            }
            return AppConfiguration()
        }
    }
    @discardableResult public func save(_ configuration: AppConfiguration) throws -> AppConfiguration {
        lock.lock(); defer { lock.unlock() }
        try configuration.validate()
        let current = try load()
        var value = configuration
        value.revision = max(current.revision, value.revision) + 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try PrivateFileIO.write(data, to: fileURL)
        return value
    }
}
