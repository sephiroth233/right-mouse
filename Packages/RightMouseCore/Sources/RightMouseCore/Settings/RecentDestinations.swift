import Foundation
import Darwin

public struct DirectoryIdentity: Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: UInt32
    public init(device: UInt64, inode: UInt64, kind: UInt32) {
        self.device = device; self.inode = inode; self.kind = kind
    }
    public static func read(_ url: URL) throws -> DirectoryIdentity {
        guard url.isFileURL else { throw ConfigurationError.invalid("最近目标必须是本地目录。") }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ConfigurationError.invalid("最近目标不可访问，请连接磁盘或重新选择目录。") }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw ConfigurationError.invalid("最近目标不再是有效目录，请重新选择。") }
        return DirectoryIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), kind: UInt32(value.st_mode & S_IFMT))
    }
}

public struct RecentDestination: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Display and matching hint only; never grants access to a file operation.
    public var path: String
    public var bookmarkData: Data
    public var directoryIdentity: DirectoryIdentity
    public var lastUsedAt: Date
    public init(id: UUID = UUID(), name: String, path: String, bookmarkData: Data, directoryIdentity: DirectoryIdentity, lastUsedAt: Date) {
        self.id = id; self.name = name; self.path = path; self.bookmarkData = bookmarkData
        self.directoryIdentity = directoryIdentity; self.lastUsedAt = lastUsedAt
    }
    public func resolve() throws -> URL {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw ConfigurationError.invalid("最近目标书签无法解析，请重新选择目录。") }
        guard !stale else { throw ConfigurationError.invalid("最近目标书签已失效，请重新选择目录。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try DirectoryIdentity.read(url) == directoryIdentity else {
            throw ConfigurationError.invalid("最近目标的目录身份已变化，不能使用同路径的替代目录。请重新选择。")
        }
        return url
    }
}

public enum RecentDestinationHistory {
    public static let capacity = 10
    public static func validate(_ history: [RecentDestination]) throws {
        guard history.count <= capacity else { throw ConfigurationError.invalid("最近目标最多保留 10 项。") }
        guard Set(history.map(\.id)).count == history.count,
              Set(history.map(\.directoryIdentity)).count == history.count else { throw ConfigurationError.invalid("最近目标含重复记录。") }
        for item in history {
            guard item.path.hasPrefix("/"), !item.path.contains("\0"), !item.name.isEmpty,
                  !item.bookmarkData.isEmpty, item.bookmarkData.count <= 1024 * 1024,
                  item.directoryIdentity.kind == UInt32(S_IFDIR) else { throw ConfigurationError.invalid("最近目标记录无效。") }
        }
    }
    /// Call only after an explicitly selected or authorized directory is accepted.
    public static func remember(_ url: URL, in history: [RecentDestination], at date: Date = Date(), replacingID: UUID? = nil) throws -> [RecentDestination] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let identity = try DirectoryIdentity.read(canonical)
        let bookmark = try canonical.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil)
        guard try DirectoryIdentity.read(canonical) == identity else { throw ConfigurationError.invalid("选择期间目录发生变化，请重新选择。") }
        let existing = history.first { $0.directoryIdentity == identity }
        let item = RecentDestination(id: replacingID ?? existing?.id ?? UUID(), name: canonical.lastPathComponent.isEmpty ? "/" : canonical.lastPathComponent,
                                     path: canonical.path, bookmarkData: bookmark, directoryIdentity: identity, lastUsedAt: date)
        var remaining = history.filter { $0.id != item.id && $0.directoryIdentity != identity && $0.path != item.path }
        remaining.insert(item, at: 0)
        let result = Array(remaining.prefix(capacity))
        try validate(result)
        return result
    }
}
