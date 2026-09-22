import Foundation
import RightMouseCore

private struct StorageSeparationHostFailure: Error, CustomStringConvertible { let description: String }

/// End-to-end host logic with distinct temporary shared/private roots. No Finder or UI.
@MainActor func runStorageSeparationHostChecks() async throws -> Int {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-host-storage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = SharedPaths(root: root.appendingPathComponent("shared"), privateRoot: root.appendingPathComponent("private"))
    try paths.prepare()
    let user = root.appendingPathComponent("user"), target = root.appendingPathComponent("destination")
    for directory in [user, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw StorageSeparationHostFailure(description: title) }
        count += 1; print("PASS storage-host: \(title)")
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    let bookmark = try target.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    let customTemplate = FileTemplate(id: "legacy-custom", name: "Legacy template", resourceName: "legacy-resource", filename: "legacy.txt")
    let templateBytes = Data("PRIVATE-TEMPLATE-BODY-\(UUID().uuidString)".utf8)
    let integrationPath = "/private/PRIVATE-APP-LOCATION-\(UUID().uuidString).app"
    var configuration = AppConfiguration()
    configuration.revealCreatedFile = false; configuration.conflictPolicy = "skip"
    configuration.favorites = [SavedLocation(name: "Legacy destination", path: target.path, bookmarkData: bookmark)]
    configuration.watchedLocations = [SavedLocation(name: "Watched fixture", path: user.path, bookmarkData: try user.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))]
    configuration.templates.append(customTemplate)
    configuration.integrations.append(AppIntegration(id: "fixture-app", name: "Fixture editor", bundleID: "test.fixture.editor", applicationPath: integrationPath))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let configBytes = try encoder.encode(configuration)
    let oldConfiguration = paths.root.appendingPathComponent("Configuration/configuration.json")
    let oldTemplate = paths.root.appendingPathComponent("Templates/legacy-resource")
    try PrivateFileIO.write(configBytes, to: oldConfiguration)
    try PrivateFileIO.write(templateBytes, to: oldTemplate)
    let historic = CommandRequest(context: ActionContext(entryPoint: .items, container: nil, selection: [FileReference(url: user.appendingPathComponent("historic.txt"))]), action: .copyText(format: .path))
    let oldCommands = paths.root.appendingPathComponent("Operations/Commands")
    let oldCommand = oldCommands.appendingPathComponent(historic.requestID.uuidString + ".json")
    do {
        let legacy = try CommandLedger(directory: oldCommands)
        var entry = try legacy.accept(historic).entry; entry.receipt.status = .completed; try legacy.save(entry)
    }
    let commandBytes = try Data(contentsOf: oldCommand)
    let brokenID = UUID(), futureID = UUID()
    let corruptBytes = Data("PRIVATE-CORRUPT-COMMAND-\(UUID().uuidString)".utf8)
    let futureBytes = Data("{\"schemaVersion\":999,\"privatePayload\":\"PRIVATE-FUTURE-TRANSFER-\(UUID().uuidString)\"}".utf8)
    try PrivateFileIO.write(corruptBytes, to: oldCommands.appendingPathComponent(brokenID.uuidString + ".json"))
    try PrivateFileIO.write(futureBytes, to: paths.root.appendingPathComponent("Operations/Transfers").appendingPathComponent(futureID.uuidString + ".json"))
    var host: HostController? = try HostController(storagePaths: paths)
    try check(try Data(contentsOf: ConfigurationStore(directory: paths.configurationDirectory).fileURL) == configBytes && host!.model.configuration == configuration, "host migrates legacy configuration bytes and loads the original settings")
    try check(try Data(contentsOf: paths.templatesDirectory.appendingPathComponent(customTemplate.resourceName)) == templateBytes && Data(contentsOf: paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(historic.requestID.uuidString + ".json")) == commandBytes, "template and terminal command raw bytes survive private migration")
    try check(!exists(oldConfiguration) && !exists(oldTemplate) && !exists(oldCommand) && !exists(paths.root.appendingPathComponent("Operations/Commands").appendingPathComponent(brokenID.uuidString + ".json")), "legacy shared configuration templates and command payloads are removed after migration")
    try check(try host!.model.configuration.favorites[0].resolve().standardizedFileURL == target.standardizedFileURL, "migrated bookmark still resolves inside the private host")
    let newFavoriteID = UUID()
    try check(host!.model.save { $0.favorites.append(SavedLocation(id: newFavoriteID, name: "New favorite", path: target.path, bookmarkData: bookmark)) } && host!.model.rememberDestination(target), "host saves a new favorite and authorized recent destination")
    let menuStore = MenuSnapshotStore(directory: paths.menuDirectory)
    let snapshot = try menuStore.load()
    try check(snapshot.available && snapshot.favorites.contains(where: { $0.id == newFavoriteID && $0.path == target.path }) && snapshot.recentDestinations.count == 1, "shared menu snapshot publishes current display IDs and paths")
    let snapshotBytes = try Data(contentsOf: menuStore.fileURL), snapshotObject = try JSONSerialization.jsonObject(with: snapshotBytes)
    func allKeys(_ object: Any) -> Set<String> {
        if let dictionary = object as? [String: Any] { return dictionary.values.reduce(into: Set(dictionary.keys)) { $0.formUnion(allKeys($1)) } }
        if let array = object as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) } }
        return []
    }
    let forbidden: Set<String> = ["bookmarkData", "accessBookmarks", "directoryIdentity", "applicationPath", "resourceName", "filename", "usesVariables", "body"]
    let snapshotText = String(decoding: snapshotBytes, as: UTF8.self)
    try check(allKeys(snapshotObject).isDisjoint(with: forbidden) && !snapshotText.contains(bookmark.base64EncodedString()) && !snapshotText.contains(integrationPath) && !snapshotText.contains(String(decoding: templateBytes, as: UTF8.self)), "shared snapshot excludes authority template bytes and application paths")
    let privateConfigBytes = try Data(contentsOf: ConfigurationStore(directory: paths.configurationDirectory).fileURL)
    let savedPrivateConfiguration = try JSONDecoder().decode(AppConfiguration.self, from: privateConfigBytes)
    try check(savedPrivateConfiguration.favorites.contains(where: { $0.bookmarkData == bookmark }) && savedPrivateConfiguration.integrations.contains(where: { $0.applicationPath == integrationPath }), "full grants and integration location remain in private configuration")
    let context = ActionContext(entryPoint: .items, container: FileReference(url: user, kindHint: .directory), selection: [FileReference(url: user.appendingPathComponent("source.txt"), kindHint: .file)])
    func semanticObject(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.filter { $0.key != "refID" }.mapValues(semanticObject) }
        if let array = value as? [Any] { return array.map(semanticObject) }
        return value
    }
    func menuShape(_ entries: [MenuEntry]) throws -> [String] {
        try entries.flatMap { entry -> [String] in
            let action = try entry.action.map { value -> String in
                let object = try JSONSerialization.jsonObject(with: WireCodec.encoder().encode(value))
                return String(decoding: try JSONSerialization.data(withJSONObject: semanticObject(object), options: [.sortedKeys]), as: UTF8.self)
            } ?? "none"
            return ["\(entry.id)|\(entry.title)|\(entry.enabled)|\(action)"] + (try menuShape(entry.children))
        }
    }
    try check(try menuShape(MenuPolicy.entries(snapshot: snapshot, context: context)) == menuShape(MenuPolicy.entries(configuration: host!.model.configuration, context: context)), "Finder snapshot and host configuration produce identical menu plans")
    let create = CommandRequest(context: ActionContext(entryPoint: .container, container: FileReference(url: target, kindHint: .directory), selection: []), action: .createFile(templateID: "txt", destination: FileReference(url: target, kindHint: .directory), name: "separated.txt"))
    guard host!.submit(create, interactive: true) else { throw StorageSeparationHostFailure(description: "create was rejected") }
    _ = try await separationWait(host!, create.requestID)
    let created = target.appendingPathComponent("separated.txt")
    try check(exists(created) && (try Data(contentsOf: created)).isEmpty, "real host creates TXT using the migrated private template configuration")
    let source = user.appendingPathComponent("source.txt"); let payload = Data("copy payload".utf8); try payload.write(to: source)
    let copy = CommandRequest(context: context, action: .transfer(mode: .copy, destination: FileReference(url: target, kindHint: .directory), conflictPolicy: .skip))
    guard host!.submit(copy, interactive: true) else { throw StorageSeparationHostFailure(description: "copy was rejected") }
    _ = try await separationWait(host!, copy.requestID)
    try check(try Data(contentsOf: target.appendingPathComponent("source.txt")) == payload && Data(contentsOf: source) == payload, "real host copy completes without changing its source")
    let receiptURL = paths.receiptsDirectory.appendingPathComponent(copy.requestID.uuidString + ".json")
    let receipt = try WireCodec.decoder().decode(CommandReceipt.self, from: Data(contentsOf: receiptURL))
    try check(receipt.status == .completed && exists(paths.root.appendingPathComponent("Receipts").appendingPathComponent(create.requestID.uuidString + ".json")) && !exists(paths.privateRoot.appendingPathComponent("Receipts")), "create and copy receipts remain in the shared transport root")
    let followup = try TaskFollowupStore(directory: paths.operationsDirectory.appendingPathComponent("Followups")).read(copy.requestID)!
    let privateLedger = paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(copy.requestID.uuidString + ".json")
    let privateJournal = paths.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(followup.result!.items[0].itemID.uuidString + ".json")
    try check(exists(privateLedger) && exists(privateJournal) && !exists(paths.root.appendingPathComponent("Operations/Followups")) && !exists(paths.root.appendingPathComponent("Operations/Transfers")), "ledger followup and transfer journal remain exclusively private")
    let preserved = try await separationBackupBytes(paths)
    try check(preserved.contains(corruptBytes) && preserved.contains(futureBytes), "startup preserves corrupt command and future transfer as private evidence")
    let privateBroken = paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(brokenID.uuidString + ".json")
    let privateFuture = paths.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(futureID.uuidString + ".json")
    try check(try Data(contentsOf: privateBroken) == corruptBytes && Data(contentsOf: privateFuture) == futureBytes && !exists(paths.root.appendingPathComponent("Backups")), "evidence preservation leaves migrated originals intact and exposes no shared backup")
    let export = try host!.model.onExportDiagnostics!()
    let exportedText = String(decoding: export.data, as: UTF8.self)
    try check(!exportedText.contains(root.path) && !exportedText.contains(String(decoding: corruptBytes, as: UTF8.self)) && !exportedText.contains("PRIVATE-FUTURE-TRANSFER") && !exportedText.contains(bookmark.base64EncodedString()) && !exportedText.contains("PRIVATE-TEMPLATE-BODY"), "diagnostic export excludes paths raw recovery evidence grants and template body")
    let originalLedgerBytes = try Data(contentsOf: privateLedger)
    try await separationRelease(&host)
    host = try HostController(storagePaths: paths)
    try check(host!.submit(copy, interactive: true), "restarted host accepts an existing ID as a duplicate")
    try await Task.sleep(nanoseconds: 50_000_000)
    try check(try Data(contentsOf: privateLedger) == originalLedgerBytes && FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).filter({ $0.lastPathComponent.hasPrefix("source") }).count == 1, "restart dedupe republishes receipt without repeating copy or rewriting its ledger")
    let repeatedPreserved = try await separationBackupBytes(paths)
    try check(repeatedPreserved.count == preserved.count && Set(repeatedPreserved) == Set(preserved), "repeated recovery scans do not add duplicate raw evidence")
    let moveSource = user.appendingPathComponent("readonly-move.txt"), movedTarget = target.appendingPathComponent("readonly-move.txt")
    try Data("undo must not run".utf8).write(to: moveSource)
    let move = CommandRequest(context: ActionContext(entryPoint: .items, container: FileReference(url: user, kindHint: .directory), selection: [FileReference(url: moveSource)]), action: .transfer(mode: .move, destination: FileReference(url: target, kindHint: .directory), conflictPolicy: .skip))
    guard host!.submit(move, interactive: true) else { throw StorageSeparationHostFailure(description: "readonly move fixture rejected") }
    let movedTask = try await separationWait(host!, move.requestID)
    let retrySource = user.appendingPathComponent("readonly-retry.txt")
    try Data("retry must not run".utf8).write(to: retrySource)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: retrySource.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retrySource.path) }
    let retry = CommandRequest(context: ActionContext(entryPoint: .items, container: FileReference(url: user, kindHint: .directory), selection: [FileReference(url: retrySource)]), action: .transfer(mode: .copy, destination: FileReference(url: target, kindHint: .directory), conflictPolicy: .skip))
    guard host!.submit(retry, interactive: true) else { throw StorageSeparationHostFailure(description: "readonly retry fixture rejected") }
    let retryTask = try await separationWait(host!, retry.requestID)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retrySource.path)
    try check(movedTask.canUndo && retryTask.canRetry && !exists(moveSource) && exists(movedTarget), "writable host produces a real undoable move and retryable failure before version change")
    try await separationRelease(&host)
    let futurePaths = paths
    let futureConfiguration = Data("{\"schemaVersion\":999,\"privateFuture\":\"KEEP-RAW\"}".utf8)
    let futureConfigurationURL = ConfigurationStore(directory: futurePaths.configurationDirectory).fileURL
    try PrivateFileIO.write(futureConfiguration, to: futureConfigurationURL)
    host = try HostController(storagePaths: futurePaths)
    try check(host!.model.isReadOnly && (try Data(contentsOf: futureConfigurationURL)) == futureConfiguration, "future private configuration remains byte intact and makes host read-only")
    try check(host!.model.tasks.first(where: { $0.id == move.requestID })?.canUndo == false && host!.model.tasks.first(where: { $0.id == retry.requestID })?.canRetry == false, "read-only history suppresses undo and retry buttons")
    let taskIDsBeforeCallbacks = Set(host!.model.tasks.map(\.id))
    host!.model.onUndoTask?(move.requestID); host!.model.onRetryTask?(retry.requestID)
    try await Task.sleep(nanoseconds: 50_000_000)
    try check(!exists(moveSource) && exists(movedTarget) && !exists(target.appendingPathComponent("readonly-retry.txt")) && Set(host!.model.tasks.map(\.id)) == taskIDsBeforeCallbacks && (try Data(contentsOf: futureConfigurationURL)) == futureConfiguration, "direct read-only undo/retry callbacks do not move files create tasks or alter future configuration")
    let unavailable = try MenuSnapshotStore(directory: futurePaths.menuDirectory).load()
    try check(!unavailable.available && unavailable.actions.isEmpty && MenuPolicy.entries(snapshot: unavailable, context: context).isEmpty, "read-only host publishes an unavailable empty shared business menu")
    let refused = CommandRequest(context: create.context, action: .createFile(templateID: "txt", destination: FileReference(url: target), name: "must-not-create.txt"))
    try check(!host!.submit(refused, interactive: true) && !exists(target.appendingPathComponent("must-not-create.txt")) && !exists(futurePaths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(refused.requestID.uuidString + ".json")), "read-only host rejects submit before recording or performing file business")
    try await separationRelease(&host)
    return count
}

@MainActor private func separationWait(_ host: HostController, _ id: UUID) async throws -> TaskPresentation {
    for _ in 0..<1000 {
        if let task = host.model.tasks.first(where: { $0.id == id }), ["完成", "部分完成", "失败", "已取消", "需要核对"].contains(task.status) { return task }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StorageSeparationHostFailure(description: "task did not reach terminal state")
}
@MainActor private func separationBackupBytes(_ paths: SharedPaths) async throws -> [Data] {
    for _ in 0..<200 {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        let bytes = try files.filter { $0.pathExtension == "bytes" }.map { try Data(contentsOf: $0) }
        if bytes.count >= 2 { return bytes }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StorageSeparationHostFailure(description: "both recovery evidence copies were not produced")
}
@MainActor private func separationRelease(_ host: inout HostController?) async throws {
    weak var prior = host; defer { prior = nil }; host = nil
    for _ in 0..<100 { if prior == nil { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    throw StorageSeparationHostFailure(description: "host retained its ledger after fixture completion")
}
