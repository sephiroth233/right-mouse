import Foundation
import RightMouseCore

private struct RecentHostFailure: Error, CustomStringConvertible { let description: String }

@MainActor func runRecentDestinationHostChecks() async throws -> Int {
    var root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-recent-host-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    root = root.resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = SharedPaths(root: root, isDevelopmentFallback: true)
    let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
    let firstTarget = root.appendingPathComponent("target-one", isDirectory: true)
    let secondTarget = root.appendingPathComponent("target-two", isDirectory: true)
    for url in [sourceDirectory, firstTarget, secondTarget] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw RecentHostFailure(description: title) }
        count += 1; print("PASS recent host: \(title)")
    }
    var host: HostController? = try HostController(storagePaths: paths)
    host!.model.save { $0.revealCreatedFile = false; $0.conflictPolicy = "skip" }
    try check(host!.model.rememberDestination(firstTarget) && host!.model.rememberDestination(secondTarget), "accepted target selections persist bookmarks")
    let firstID = host!.model.configuration.recentDestinations.first { $0.path == firstTarget.path }!.id
    let secondID = host!.model.configuration.recentDestinations.first { $0.path == secondTarget.path }!.id
    try check(host!.model.selectRecentDestination(firstID) && (try host!.model.destination.map(DirectoryIdentity.read)) == DirectoryIdentity.read(firstTarget) && host!.model.selectedRecentDestinationID == firstID, "recent target selection resolves bookmark and carries stable token")
    try check(host!.model.configuration.recentDestinations.map(\.id) == [firstID, secondID], "selecting a recent destination updates LRU order")
    let persisted = try ConfigurationStore(directory: paths.configurationDirectory).load()
    try check(persisted.recentDestinations.map(\.id) == [firstID, secondID], "recent LRU changes reach persisted configuration")
    let source = sourceDirectory.appendingPathComponent("picker-copy.txt")
    try Data("picker-copy".utf8).write(to: source)
    host!.model.selectedFiles = [source]
    let existing = Set(host!.model.tasks.map(\.id))
    host!.model.perform("copyTo")
    let pickerTask = try await recentHostWait(host!) { !existing.contains($0.id) && $0.status == "完成" }
    try check((try? Data(contentsOf: firstTarget.appendingPathComponent(source.lastPathComponent))) == Data("picker-copy".utf8), "operation-table recent target completes a real copy")
    let ledgerData = try PrivateFileIO.read(paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(pickerTask.id.uuidString + ".json"))
    let entry = try WireCodec.decoder().decode(LedgerEntry.self, from: ledgerData)
    guard case let .transfer(_, destination, _) = entry.request.action else { throw RecentHostFailure(description: "picker emitted wrong action") }
    try check(destination?.bookmarkToken == firstID, "host command retains UI-selected recent token")

    // Source is explicitly watched; target access exists only through recent history.
    let sourceBookmark = try sourceDirectory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    host!.model.save { $0.watchedLocations = [.init(name: "fixture source", path: sourceDirectory.path, bookmarkData: sourceBookmark)] }
    let finderSource = sourceDirectory.appendingPathComponent("finder-copy.txt")
    try Data("finder-copy".utf8).write(to: finderSource)
    func request(_ id: UUID, target: URL, source: URL = finderSource) -> CommandRequest {
        CommandRequest(context: ActionContext(entryPoint: .items, container: nil, selection: [FileReference(url: source, kindHint: .file)]),
                       action: .transfer(mode: .copy, destination: FileReference(refID: id, url: target, kindHint: .directory, bookmarkToken: id), conflictPolicy: .skip))
    }
    let finderRequest = request(firstID, target: firstTarget)
    host!.submit(finderRequest)
    _ = try await recentHostWait(host!) { $0.id == finderRequest.requestID && $0.status == "完成" }
    try check((try? Data(contentsOf: firstTarget.appendingPathComponent(finderSource.lastPathComponent))) == Data("finder-copy".utf8), "Finder-style command authorizes target through recent bookmark")
    try check(host!.model.configuration.favorites.isEmpty && host!.model.configuration.watchedLocations.allSatisfy { $0.path != firstTarget.path }, "recent target access is not accidentally supplied by another grant")

    host!.model.removeRecentDestination(secondID)
    let removed = request(secondID, target: secondTarget)
    host!.submit(removed)
    _ = try await recentHostWait(host!) { $0.id == removed.requestID && $0.status == "失败" }
    try check(try FileManager.default.contentsOfDirectory(atPath: secondTarget.path).isEmpty, "removed recent token cannot fall back to a still-existing directory")
    let unknown = request(UUID(), target: firstTarget)
    host!.submit(unknown)
    _ = try await recentHostWait(host!) { $0.id == unknown.requestID && $0.status == "失败" }
    try check(host!.model.errorMessage != nil, "unknown recent token is visibly rejected")

    host!.model.rememberDestination(secondTarget)
    let repairID = host!.model.configuration.recentDestinations.first!.id
    host!.model.save { $0.recentDestinations[0].bookmarkData = Data([0, 1, 2]) }
    host!.model.refreshRecentDestinations()
    try check(host!.model.recentDestinationIssues[repairID] != nil && !host!.model.selectRecentDestination(repairID), "invalid recent bookmark shows repair state and cannot be selected")
    // Probe AppModel dispatch without invoking clipboard/application side effects.
    let originalCallback = host!.model.onPerformAction
    var forwarded: [String] = []
    host!.model.selectedRecentDestinationID = repairID
    host!.model.onPerformAction = { action, _, _ in forwarded.append(action) }
    for action in ["copyText:path", "stageMove", "openWith:vscode"] { host!.model.perform(action) }
    try check(forwarded == ["copyText:path", "stageMove", "openWith:vscode"], "invalid recent target does not block unrelated AppModel actions")
    host!.model.perform("copyTo")
    try check(forwarded.count == 3, "invalid recent target still blocks a target-dependent AppModel action")
    host!.model.onPerformAction = originalCallback
    let corrupt = request(repairID, target: secondTarget)
    host!.submit(corrupt)
    _ = try await recentHostWait(host!) { $0.id == corrupt.requestID && $0.status == "失败" }
    try check(try FileManager.default.contentsOfDirectory(atPath: secondTarget.path).isEmpty, "invalid bookmark never authorizes the display path")
    try check(host!.model.repairRecentDestination(repairID, with: secondTarget) && host!.model.recentDestinationIssues[repairID] == nil, "accepted repair replaces bookmark and clears invalid state")
    try check(host!.model.selectRecentDestination(repairID), "repaired destination can be selected")
    weak var oldHost = host
    host = nil
    for _ in 0..<100 where oldHost != nil { try await Task.sleep(nanoseconds: 10_000_000) }
    try check(oldHost == nil, "fixture host releases its ledger before reopening")
    oldHost = nil
    host = try HostController(storagePaths: paths)
    try check(host!.model.configuration.recentDestinations.first?.id == repairID && (try DirectoryIdentity.read(host!.model.configuration.recentDestinations.first!.resolve())) == DirectoryIdentity.read(secondTarget), "host restart preserves repaired recent authorization and order")
    host!.model.selectRecentDestination(repairID)
    host!.model.clearRecentDestinations()
    try check(host!.model.configuration.recentDestinations.isEmpty && host!.model.selectedRecentDestinationID == nil && host!.model.destination == nil, "clearing history clears an active recent selection")
    try check(FileManager.default.fileExists(atPath: firstTarget.path) && FileManager.default.fileExists(atPath: secondTarget.path), "removing and clearing recent records never deletes directories")
    try check(try ConfigurationStore(directory: paths.configurationDirectory).load().recentDestinations.isEmpty, "cleared history remains empty on disk")
    return count
}

@MainActor private func recentHostWait(_ host: HostController, matching: (TaskPresentation) -> Bool) async throws -> TaskPresentation {
    for _ in 0..<1500 {
        if let task = host.model.tasks.first(where: matching) { return task }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw RecentHostFailure(description: "recent target task timed out: \(host.model.errorMessage ?? "no error")")
}
