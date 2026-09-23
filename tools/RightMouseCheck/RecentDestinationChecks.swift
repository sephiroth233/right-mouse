import Foundation
import RightMouseCore

private struct RecentCheckFailure: Error, CustomStringConvertible {
    let description: String
}

func runRecentDestinationChecks() throws -> Int {
    var root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-recent-core-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    root = root.resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw RecentCheckFailure(description: name) }
        count += 1
    }
    func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch { count += 1; return }
        throw RecentCheckFailure(description: name)
    }
    var legacy = AppConfiguration()
    legacy.revision = 42; legacy.compactMenu = true; legacy.actions[0].groupID = "旧配置分组"
    legacy.templates[0].name = "原有模板名称"
    let encoded = try JSONEncoder().encode(legacy)
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    object.removeValue(forKey: "recentDestinations")
    let legacyBytes = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacyBytes)
    try check(decoded == legacy && decoded.recentDestinations.isEmpty, "schema-1 legacy configuration lost existing fields")
    let store = ConfigurationStore(directory: root.appendingPathComponent("configuration"))
    try PrivateFileIO.write(legacyBytes, to: store.fileURL)
    try check(try store.load() == legacy && store.lastWarning == nil, "legacy configuration was incorrectly treated as corrupt")
    var history: [RecentDestination] = []
    var directories: [URL] = []
    for index in 0..<12 {
        let url = root.appendingPathComponent("target-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        history = try RecentDestinationHistory.remember(url, in: history, at: Date(timeIntervalSince1970: Double(index)))
    }
    try check(history.count == 10 && history.first?.path == directories[11].path && history.last?.path == directories[2].path, "recent LRU did not evict the oldest targets")
    let prior = history.first { $0.path == directories[5].path }!
    history = try RecentDestinationHistory.remember(directories[5], in: history, at: Date(timeIntervalSince1970: 100))
    try check(history.count == 10 && history.first?.id == prior.id && history.first?.lastUsedAt == Date(timeIntervalSince1970: 100), "reuse duplicated the target or did not move it to the front")
    let resolvedOriginal = try history[0].resolve()
    let expectedIdentity = try DirectoryIdentity.read(directories[5])
    print("Recent bookmark fixture: requested=\(directories[5].absoluteString), resolved=\(resolvedOriginal.absoluteString), identity=\(expectedIdentity)")
    try check(try DirectoryIdentity.read(resolvedOriginal) == expectedIdentity && expectedIdentity == history[0].directoryIdentity, "valid security bookmark did not resolve to captured directory identity")
    let alias = root.appendingPathComponent("target-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directories[5])
    history = try RecentDestinationHistory.remember(alias, in: history)
    try check(history.count == 10 && history[0].id == prior.id, "alias of an existing target created a second identity")
    var config = decoded; config.recentDestinations = history
    let saved = try store.save(config)
    try check(try store.load() == saved && saved.revision == 43 && saved.actions[0].groupID == "旧配置分组", "recent persistence did not preserve legacy configuration and revision")
    let beforeOversize = try Data(contentsOf: store.fileURL)
    var oversizedBytes = saved
    for index in oversizedBytes.recentDestinations.indices { oversizedBytes.recentDestinations[index].bookmarkData = Data(repeating: 0x41, count: 1024 * 1024) }
    try rejects("oversized encoded configuration was written beyond the reader limit") { _ = try store.save(oversizedBytes) }
    try check(try Data(contentsOf: store.fileURL) == beforeOversize && store.load() == saved, "oversized save changed the previous readable configuration")
    var corruptBookmark = history[0]; corruptBookmark.bookmarkData = Data([0, 1, 2])
    try rejects("corrupt bookmark fell back to an existing path") { _ = try corruptBookmark.resolve() }
    var wrongIdentity = history[0]
    wrongIdentity.directoryIdentity = DirectoryIdentity(device: wrongIdentity.directoryIdentity.device, inode: wrongIdentity.directoryIdentity.inode + 1, kind: wrongIdentity.directoryIdentity.kind)
    try rejects("valid bookmark bypassed captured directory identity") { _ = try wrongIdentity.resolve() }
    var oversized = config; oversized.recentDestinations.append(history[0])
    try rejects("eleven recent records were accepted") { try oversized.validate() }
    var duplicate = config; duplicate.recentDestinations[1].id = duplicate.recentDestinations[0].id
    try rejects("duplicate recent IDs were accepted") { try duplicate.validate() }
    let single = ActionContext(entryPoint: .items, container: FileReference(url: root, kindHint: .directory), selection: [FileReference(url: root.appendingPathComponent("sample.txt"), kindHint: .file)])
    config.favorites = [.init(name: "重复收藏", path: history[0].path)]
    let menu = MenuPolicy.entries(configuration: config, context: single)
    func find(_ id: String, in entries: [MenuEntry]) -> MenuEntry? {
        for entry in entries { if entry.id == id { return entry }; if let nested = find(id, in: entry.children) { return nested } }
        return nil
    }
    try check(find("copy.recent", in: menu) == nil, "legacy history must not reintroduce recent copy destinations")
    try check(find("move.recent", in: menu) == nil, "legacy history must not reintroduce recent move destinations")
    for mode in [CommandTransferMode.copy, .move] {
        let favoriteID = config.favorites[0].id
        guard case let .transfer(actualMode, destination, policy)? = find("\(mode.rawValue).\(favoriteID)", in: menu)?.action else {
            throw RecentCheckFailure(description: "favorite target missing after removing recent targets")
        }
        try check(actualMode == mode && destination?.bookmarkToken == favoriteID && policy == .ask,
                  "favorite destination retains its authorization token and asks on conflicts")
        try check(find("\(mode.rawValue).choose", in: menu)?.action == .transfer(mode: mode, destination: nil, conflictPolicy: .ask),
                  "directory picker remains available without recent destinations")
    }
    // Rename the original object and install a different object at its former path.
    let original = history[0]
    let retained = root.appendingPathComponent("original-retained", isDirectory: true)
    try FileManager.default.moveItem(at: directories[5], to: retained)
    try FileManager.default.createDirectory(at: directories[5], withIntermediateDirectories: true)
    let resolved = try? original.resolve()
    try check(resolved == nil || (try DirectoryIdentity.read(resolved!)) == original.directoryIdentity, "bookmark resolution silently chose a same-path replacement")
    try check(resolved?.standardizedFileURL.path != directories[5].standardizedFileURL.path, "renamed bookmark fell back to the replacement path")
    let repaired = try RecentDestinationHistory.remember(directories[5], in: history, replacingID: original.id)
    try check(repaired[0].id == original.id && (try DirectoryIdentity.read(repaired[0].resolve())) == DirectoryIdentity.read(directories[5]), "explicit repair did not save fresh directory authorization")
    try check(FileManager.default.fileExists(atPath: retained.path), "repair removed the preserved original directory")
    return count
}
