import Foundation
import RightMouseCore

private struct ConfigurationLimitFailure: Error, CustomStringConvertible { let description: String }

/// The byte boundary applies to actual JSON bytes, independently of the item-count limit.
func runConfigurationLimitChecks() throws -> Int {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("rightmouse-config-limit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConfigurationStore(directory: root.appendingPathComponent("Configuration"))
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw ConfigurationLimitFailure(description: name) }
        count += 1
    }
    func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }
        throw ConfigurationLimitFailure(description: name)
    }
    // Schema 1 does not cap display-title length. Use its full 100-action count
    // and long valid ASCII titles to exercise the on-disk byte boundary without
    // synthetic bookmark grants or external files.
    var large = AppConfiguration()
    let title = String(repeating: "x", count: 24 * 1024)
    large.actions = (0..<100).map { ConfiguredAction(id: "limit-\($0)", commandType: "copyText", title: "\($0)-" + title, order: $0) }
    try large.validate()
    let saved = try store.save(large)
    let bytes = try Data(contentsOf: store.fileURL)
    try check(bytes.count > 2 * 1024 * 1024 && bytes.count < ConfigurationStore.maximumBytes, "fixture does not exercise a valid 2–8 MiB configuration")
    try check(try store.load() == saved && store.load(readOnly: true) == saved, "host cannot roundtrip a valid configuration larger than 2 MiB")
    let menu = MenuSnapshotStore(directory: root.appendingPathComponent("Menu"))
    try menu.publish(saved)
    let finderConfig = try menu.load()
    try check(finderConfig == MenuConfigurationSnapshot(configuration: saved), "Finder projection differs from the saved host configuration")
    try check(finderConfig.actions.count == 100 && finderConfig.actions.last?.title == large.actions.last?.title, "large configuration was silently truncated")

    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var boundary = saved
    // Account for the revision increment performed by save before padding to the
    // exact public byte limit. ASCII x adds exactly one JSON byte per character.
    boundary.revision += 1
    let baseBytes = try encoder.encode(boundary).count
    boundary.actions[0].title += String(repeating: "x", count: ConfigurationStore.maximumBytes - baseBytes)
    boundary.revision = saved.revision
    let exactSaved = try store.save(boundary)
    let exactBytes = try Data(contentsOf: store.fileURL)
    try check(exactBytes.count == ConfigurationStore.maximumBytes, "exact-limit configuration was rejected or encoded at the wrong size")
    try menu.publish(exactSaved)
    let exactFinder = try menu.load()
    try check(try store.load() == exactSaved && exactFinder == MenuConfigurationSnapshot(configuration: exactSaved), "exact-limit host/Finder projection acceptance differs")

    var tooLarge = exactSaved
    tooLarge.actions[0].title += "x"
    try tooLarge.validate()
    try rejects("above-limit save was accepted") { _ = try store.save(tooLarge) }
    try check(try Data(contentsOf: store.fileURL) == exactBytes && store.load() == exactSaved, "rejected oversized save changed the previous configuration")
    try check(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == [store.fileURL.lastPathComponent], "rejected save left a temporary file or spurious corruption backup")

    // Independently verify that a pre-existing oversized file is rejected by
    // both readers, rather than decoded as defaults or truncated.
    let externalDirectory = root.appendingPathComponent("Oversized")
    let externalStore = ConfigurationStore(directory: externalDirectory)
    try PrivateFileIO.write(try encoder.encode(tooLarge), to: externalStore.fileURL)
    try rejects("host reader accepted over-limit bytes") { _ = try externalStore.load() }
    let invalidMenu = MenuSnapshotStore(directory: root.appendingPathComponent("OversizedMenu"))
    try PrivateFileIO.write(Data(repeating: 0x20, count: MenuSnapshotStore.maximumBytes + 1), to: invalidMenu.fileURL)
    try rejects("Finder snapshot reader accepted over-limit bytes") { _ = try invalidMenu.load() }
    return count
}
