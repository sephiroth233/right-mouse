import Foundation
import Darwin
import RightMouseCore

private struct StorageSeparationFailure: Error, CustomStringConvertible { let description: String }

func runStorageSeparationChecks() throws -> Int {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("rightmouse-layout-\(UUID().uuidString)")
    try PrivateFileIO.ensureDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw StorageSeparationFailure(description: title) }
        count += 1; print("PASS storage separation: \(title)")
    }
    func rejects(_ title: String, _ action: () throws -> Void) throws {
        do { try action() } catch { count += 1; print("PASS storage separation: \(title)"); return }
        throw StorageSeparationFailure(description: title)
    }
    let shared = root.appendingPathComponent("shared")
    let privateRoot = root.appendingPathComponent("private")
    let legacy = SharedPaths(root: shared)
    try legacy.prepare()
    let bookmarkSecret = Data("private-bookmark-grant-do-not-publish".utf8)
    var configuration = AppConfiguration()
    configuration.favorites = [.init(name: "Project", path: "/fixture/project", bookmarkData: bookmarkSecret)]
    configuration.watchedLocations = [.init(name: "Watch", path: "/fixture/watch", bookmarkData: bookmarkSecret)]
    configuration.templates.append(.init(id: "custom", name: "Custom", resourceName: "private-template-resource", filename: "private-template-name.txt"))
    configuration.integrations.append(.init(id: "custom", name: "Custom App", bundleID: "private.bundle", applicationPath: "/Applications/Private App.app"))
    let saved = try ConfigurationStore(directory: legacy.configurationDirectory).save(configuration)
    let originalConfig = try PrivateFileIO.read(legacy.configurationDirectory.appendingPathComponent("configuration.json"), maximumBytes: ConfigurationStore.maximumBytes)
    let template = Data("private-template-content".utf8)
    try PrivateFileIO.write(template, to: legacy.templatesDirectory.appendingPathComponent("private-template-resource"))
    let operationID = UUID()
    let command = legacy.operationsDirectory.appendingPathComponent("Commands/\(operationID.uuidString).json")
    let rawEvidence = Data("damaged-raw-command-with-private-path".utf8)
    try PrivateFileIO.write(rawEvidence, to: command)
    let paths = SharedPaths(root: shared, privateRoot: privateRoot)
    try paths.prepare()
    var lease: PrivateStorageMigration? = try PrivateStorageMigration(paths: paths)
    try rejects("migration lease fences the old host ledger") { _ = try CommandLedger(directory: legacy.operationsDirectory.appendingPathComponent("Commands")) }
    try lease!.run()
    try check(lease!.migratedFiles == 3, "legacy configuration template and operation bytes are relocated")
    try check(try ConfigurationStore(directory: paths.configurationDirectory).load() == saved, "private host configuration retains grants and revision")
    try check(try PrivateFileIO.read(paths.configurationDirectory.appendingPathComponent("configuration.json"), maximumBytes: ConfigurationStore.maximumBytes) == originalConfig, "migration preserves original configuration bytes")
    try check(try PrivateFileIO.read(paths.templatesDirectory.appendingPathComponent("private-template-resource")) == template, "migration preserves template bytes")
    try check(try PrivateFileIO.read(paths.operationsDirectory.appendingPathComponent("Commands/\(operationID.uuidString).json")) == rawEvidence, "damaged operation evidence moves without business decoding")
    try check(!FileManager.default.fileExists(atPath: command.path) && !FileManager.default.fileExists(atPath: legacy.configurationDirectory.appendingPathComponent("configuration.json").path), "legacy shared paths no longer expose private payloads")
    try lease!.run()
    try check(lease!.migratedFiles == 3, "repeat migration is idempotent after relocation")
    lease = nil
    let snapshotStore = MenuSnapshotStore(directory: paths.menuDirectory)
    try snapshotStore.publish(saved)
    let snapshot = try snapshotStore.load()
    let projection = String(decoding: try PrivateFileIO.read(snapshotStore.fileURL, maximumBytes: MenuSnapshotStore.maximumBytes), as: UTF8.self)
    try check(!projection.contains(bookmarkSecret.base64EncodedString()) && !projection.contains("bookmarkData") && !projection.contains("resourceName") && !projection.contains("applicationPath") && !projection.contains("private-template"), "Finder projection excludes authority resources and application paths")
    try check(snapshot.favorites.first?.id == saved.favorites.first?.id && snapshot.watchedLocations.first?.path == "/fixture/watch", "snapshot retains stable reference IDs and watched UI scope")
    let context = ActionContext(entryPoint: .items, container: nil, selection: [.init(url: URL(fileURLWithPath: "/fixture/source.txt"), kindHint: .file)])
    func flatten(_ entries: [MenuEntry]) -> [String] { entries.flatMap { [$0.id + "|" + $0.title] + flatten($0.children) } }
    try check(flatten(MenuPolicy.entries(configuration: saved, context: context)) == flatten(MenuPolicy.entries(snapshot: snapshot, context: context)), "host preview and Finder projection produce the same menu structure")
    let target = MenuPolicy.entries(snapshot: snapshot, context: context).first { $0.id == "copyTo" }!
    if case let .transfer(_, destination, _) = target.action {
        try check(destination == nil, "Finder transfer requests a picker instead of using legacy favorites")
    } else { throw StorageSeparationFailure(description: "missing transfer action") }
    try snapshotStore.publish(saved, available: false)
    try check(try MenuPolicy.entries(snapshot: snapshotStore.load(), context: context).isEmpty, "unavailable snapshot exposes no business commands")
    var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
    future["schemaVersion"] = 999
    try PrivateFileIO.write(JSONSerialization.data(withJSONObject: future), to: snapshotStore.fileURL)
    try rejects("future snapshot is rejected without falling back to a full private configuration") { _ = try snapshotStore.load() }
    let futureBytes = try PrivateFileIO.read(snapshotStore.fileURL)
    try rejects("publishing an unavailable snapshot does not downgrade a future schema") { try snapshotStore.publish(saved, available: false) }
    try check(try PrivateFileIO.read(snapshotStore.fileURL) == futureBytes, "future snapshot bytes survive an older host publish attempt")

    let conflictShared = root.appendingPathComponent("conflict-shared"), conflictPrivate = root.appendingPathComponent("conflict-private")
    let conflictPaths = SharedPaths(root: conflictShared, privateRoot: conflictPrivate)
    try conflictPaths.prepare()
    let oldConfig = conflictShared.appendingPathComponent("Configuration/configuration.json")
    let oldTemplate = conflictShared.appendingPathComponent("Templates/template")
    try PrivateFileIO.write(Data("first-step".utf8), to: oldConfig)
    try PrivateFileIO.write(Data("old-template".utf8), to: oldTemplate)
    let newTemplate = conflictPaths.templatesDirectory.appendingPathComponent("template")
    try PrivateFileIO.write(Data("new-occupant".utf8), to: newTemplate)
    let partial = try PrivateStorageMigration(paths: conflictPaths)
    try rejects("migration stops at a conflicting destination without overwrite") { try partial.run() }
    try check(try PrivateFileIO.read(newTemplate) == Data("new-occupant".utf8) && PrivateFileIO.read(oldTemplate) == Data("old-template".utf8), "both conflicting versions survive")
    try check(!FileManager.default.fileExists(atPath: oldConfig.path) && (try PrivateFileIO.read(conflictPaths.configurationDirectory.appendingPathComponent("configuration.json"))) == Data("first-step".utf8), "completed relocation survives later migration failure")
    try FileManager.default.removeItem(at: newTemplate) // Disposable fixture resolution.
    try partial.run()
    try check(try PrivateFileIO.read(newTemplate) == Data("old-template".utf8), "resumed migration completes without replaying the moved configuration")

    let linkedPaths = SharedPaths(root: root.appendingPathComponent("linked-shared"), privateRoot: root.appendingPathComponent("linked-private"))
    try linkedPaths.prepare()
    let external = root.appendingPathComponent("external")
    try PrivateFileIO.write(Data("external-sentinel".utf8), to: external)
    try PrivateFileIO.ensureDirectory(linkedPaths.root.appendingPathComponent("Templates"))
    let link = linkedPaths.root.appendingPathComponent("Templates/unsafe")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    try rejects("legacy symbolic links stop migration") { try PrivateStorageMigration(paths: linkedPaths).run() }
    try check(try PrivateFileIO.read(external) == Data("external-sentinel".utf8), "migration never changes an external symlink target")
    try FileManager.default.removeItem(at: link)
    try FileManager.default.linkItem(at: external, to: link)
    try rejects("legacy hardlinks stop migration before permission changes") { try PrivateStorageMigration(paths: linkedPaths).run() }
    return count
}
