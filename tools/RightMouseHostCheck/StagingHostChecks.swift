import Foundation
import Darwin
import RightMouseCore

private struct StagingHostFailure: Error, CustomStringConvertible { let description: String }
private struct StagingHostFixture {
    let paths: SharedPaths
    let request: CommandRequest
    let itemID: UUID
    let source: URL
    let target: URL
    let stage: URL
    var journalURL: URL { paths.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(itemID.uuidString + ".json") }
    var receiptURL: URL { paths.receiptsDirectory.appendingPathComponent(request.requestID.uuidString + ".json") }
}

@MainActor func runStagingHostChecks() async throws -> Int {
    let requested = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-host-stage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let physical = realpath(requested.path, nil) else { throw POSIXError(.ENOENT) }
    let root = URL(fileURLWithPath: String(cString: physical)); free(physical)
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try value() else { throw StagingHostFailure(description: title) }; count += 1; print("PASS staging-host: \(title)")
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func setup(_ label: String, authorized: Bool = true) throws -> StagingHostFixture {
        let base = root.appendingPathComponent(label)
        let paths = SharedPaths(root: base.appendingPathComponent("shared"), privateRoot: base.appendingPathComponent("private")); try paths.prepare()
        let sourceDirectory = base.appendingPathComponent("sources"), target = base.appendingPathComponent("target")
        for directory in [sourceDirectory, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let source = sourceDirectory.appendingPathComponent("user.txt")
        try Data("original source".utf8).write(to: source)
        try Data("existing target sentinel".utf8).write(to: target.appendingPathComponent("sentinel.txt"))
        let request = CommandRequest(context: ActionContext(entryPoint: .items, container: FileReference(url: sourceDirectory, kindHint: .directory), selection: [FileReference(url: source, kindHint: .file)]), action: .transfer(mode: .copy, destination: FileReference(url: target, kindHint: .directory), conflictPolicy: .ask))
        do { let ledger = try CommandLedger(directory: paths.operationsDirectory.appendingPathComponent("Commands")); _ = try ledger.accept(request) }
        let itemID = UUID(), stage = target.appendingPathComponent(".rightmouse-" + itemID.uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(repeating: 65, count: 8192).write(to: stage.appendingPathComponent("payload"))
        var followup = TaskFollowupRecord(requestID: request.requestID, destination: target)
        if authorized { followup.accessBookmarks = try [sourceDirectory, target].map { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) } }
        try TaskFollowupStore(directory: paths.operationsDirectory.appendingPathComponent("Followups")).save(followup)
        // The fixture models a process stopped in staging: ownership comes from
        // actual lstat values, not invented inode/device values or a session grant.
        let journal = StagingHostJournal(operationID: request.requestID, itemID: itemID, source: source, destination: target.appendingPathComponent(source.lastPathComponent), sourceIdentity: try stagingHostIdentity(source), stagingURL: stage, stagingIdentity: try stagingHostIdentity(stage), stagingParentIdentity: try stagingHostIdentity(target))
        let fixture = StagingHostFixture(paths: paths, request: request, itemID: itemID, source: source, target: target, stage: stage)
        try PrivateFileIO.write(JSONEncoder().encode(journal), to: fixture.journalURL)
        return fixture
    }

    // Hold a real transfer at its conflict prompt, then enqueue cleanup behind it.
    do {
        let fixture = try setup("authorized-queue")
        var prompt: CheckedContinuation<ConflictResolution, Never>?
        var host: HostController? = try HostController(storagePaths: fixture.paths, conflictPrompt: { _, _, _ in
            await withCheckedContinuation { prompt = $0 }
        })
        let restored = try WireCodec.decoder().decode(CommandReceipt.self, from: Data(contentsOf: fixture.receiptURL))
        try check(restored.status == .needsReview && host!.model.tasks.first(where: { $0.id == fixture.request.requestID })?.status == "需要核对", "startup restores staging operation as needsReview without replay")
        let receiptBefore = try Data(contentsOf: fixture.receiptURL)
        let token = try await stagingHostAllowed(host!, fixture)
        try check(host!.model.taskReview?.items.first(where: { $0.id == fixture.itemID })?.staging?.occupiedBytes ?? 0 > 0, "authorized review exposes an owned staging cleanup token and occupied bytes")
        let queueSource = fixture.source.deletingLastPathComponent().appendingPathComponent("queued.txt")
        try Data("incoming queue file".utf8).write(to: queueSource)
        try Data("queue occupant".utf8).write(to: fixture.target.appendingPathComponent("queued.txt"))
        let queueRequest = CommandRequest(context: ActionContext(entryPoint: .items, container: FileReference(url: queueSource.deletingLastPathComponent()), selection: [FileReference(url: queueSource)]), action: .transfer(mode: .copy, destination: FileReference(url: fixture.target), conflictPolicy: .ask))
        guard host!.submit(queueRequest, interactive: true) else { throw StagingHostFailure(description: "queue fixture rejected") }
        for _ in 0..<200 { if prompt != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard prompt != nil else { throw StagingHostFailure(description: "queue transfer never entered conflict prompt") }
        let accepted = host!.model.beginStagingCleanup(token)
        let duplicate = host!.model.beginStagingCleanup(token)
        try check(accepted && !duplicate, "first cleanup is admitted and an immediate repeated click is rejected")
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(host!.model.isCleaningStaging && exists(fixture.stage) && host!.model.tasks.first(where: { $0.id == queueRequest.requestID })?.status == "等待选择", "cleanup waits behind an active transfer in the global host queue")
        prompt!.resume(returning: .init(decision: .skip)); prompt = nil
        try await stagingHostWaitCleanup(host!)
        for _ in 0..<200 {
            if host!.model.taskReview?.items.first(where: { $0.id == fixture.itemID })?.staging == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(!exists(fixture.stage) && (try Data(contentsOf: fixture.source)) == Data("original source".utf8) && (try Data(contentsOf: fixture.target.appendingPathComponent("sentinel.txt"))) == Data("existing target sentinel".utf8) && !exists(fixture.target.appendingPathComponent("user.txt")), "cleanup removes only staging while source existing target and uncommitted destination remain unchanged")
        let journal = try JSONDecoder().decode(TransferJournalRecord.self, from: Data(contentsOf: fixture.journalURL))
        try check(journal.stagingCleanupState == .completed && journal.stagingURL == nil && journal.result == nil, "cleanup completion is durable without inventing an original transfer result")
        try check(try Data(contentsOf: fixture.receiptURL) == receiptBefore, "cleanup does not rewrite the original needsReview receipt into success")
        try check(host!.model.reviewError == nil && !host!.model.isCleaningStaging && host!.model.taskReview?.items.first(where: { $0.id == fixture.itemID })?.staging == nil, "review refresh removes the cleanup action after completion")
        let completedJournalBytes = try Data(contentsOf: fixture.journalURL)
        try check(!host!.model.beginStagingCleanup(token), "completed review rejects a stale repeated cleanup click")
        host!.model.onCleanupStaging?(token)
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(try Data(contentsOf: fixture.journalURL) == completedJournalBytes && Data(contentsOf: fixture.receiptURL) == receiptBefore, "direct stale cleanup callback does not repeat deletion or rewrite outcome")
        try await stagingHostRelease(&host)
    }
    do {
        let fixture = try setup("no-authorization", authorized: false)
        var host: HostController? = try HostController(storagePaths: fixture.paths)
        let item = try await stagingHostReview(host!, fixture)
        if case .retainedForReview = item.disposition { try check(item.occupiedBytes == 0 && exists(fixture.stage), "missing authorization yields display-only review without staging scan") }
        else { throw StagingHostFailure(description: "unauthorized staging unexpectedly allowed") }
        try check(try Data(contentsOf: fixture.source) == Data("original source".utf8) && Data(contentsOf: fixture.stage.appendingPathComponent("payload")).count == 8192, "unauthorized review leaves source and staging untouched")
        try await stagingHostRelease(&host)
    }
    for replacement in ["source", "stage"] {
        let fixture = try setup("replace-" + replacement)
        var host: HostController? = try HostController(storagePaths: fixture.paths)
        let token = try await stagingHostAllowed(host!, fixture)
        let original = replacement == "source" ? fixture.source : fixture.stage
        let displaced = original.appendingPathExtension("original")
        try FileManager.default.moveItem(at: original, to: displaced)
        if replacement == "source" { try Data("replacement source".utf8).write(to: original) }
        else {
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("replacement stage".utf8).write(to: original.appendingPathComponent("payload"))
        }
        guard host!.model.beginStagingCleanup(token) else { throw StagingHostFailure(description: "stale cleanup never reached host recheck") }
        try await stagingHostWaitCleanup(host!)
        try check(host!.model.reviewError != nil && exists(fixture.stage) && exists(displaced), "\(replacement) identity change after review refuses cleanup and preserves both objects")
        try check(try Data(contentsOf: fixture.target.appendingPathComponent("sentinel.txt")) == Data("existing target sentinel".utf8) && !exists(fixture.target.appendingPathComponent("user.txt")), "\(replacement) identity refusal never commits or changes the user target")
        try await stagingHostRelease(&host)
    }
    do {
        let fixture = try setup("read-only")
        var host: HostController? = try HostController(storagePaths: fixture.paths)
        let token = try await stagingHostAllowed(host!, fixture)
        try await stagingHostRelease(&host)
        let future = Data("{\"schemaVersion\":999}".utf8)
        let configuration = fixture.paths.configurationDirectory.appendingPathComponent("configuration.json")
        try PrivateFileIO.write(future, to: configuration)
        host = try HostController(storagePaths: fixture.paths)
        let journalBefore = try Data(contentsOf: fixture.journalURL)
        try check(host!.model.isReadOnly && !host!.model.beginStagingCleanup(token), "future configuration rejects model cleanup admission")
        host!.model.onCleanupStaging?(token)
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(exists(fixture.stage) && (try Data(contentsOf: fixture.journalURL)) == journalBefore && (try Data(contentsOf: configuration)) == future, "direct read-only callback cannot delete staging or alter evidence and future configuration")
        try await stagingHostRelease(&host)
    }
    return count
}

private struct StagingHostJournal: Encodable {
    var schemaVersion = 1
    let operationID: UUID; let itemID: UUID; let source: URL; let destination: URL
    let mode = TransferMode.copy; let phase = "staging"
    let sourceIdentity: TransferFileIdentity; let stagingURL: URL
    let stagingIdentity: TransferFileIdentity; let stagingParentIdentity: TransferFileIdentity
}
private func stagingHostIdentity(_ url: URL) throws -> TransferFileIdentity {
    var info = stat(); guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    let fields: [String: Any] = ["device": UInt64(info.st_dev), "inode": UInt64(info.st_ino), "kind": UInt32(info.st_mode & S_IFMT), "size": info.st_size, "modifiedSeconds": Int64(info.st_mtimespec.tv_sec), "modifiedNanoseconds": Int64(info.st_mtimespec.tv_nsec), "changedSeconds": Int64(info.st_ctimespec.tv_sec), "changedNanoseconds": Int64(info.st_ctimespec.tv_nsec)]
    return try JSONDecoder().decode(TransferFileIdentity.self, from: JSONSerialization.data(withJSONObject: fields))
}
@MainActor private func stagingHostReview(_ host: HostController, _ fixture: StagingHostFixture) async throws -> StagingRecoveryItem {
    host.model.onReviewTask?(fixture.request.requestID)
    for _ in 0..<200 {
        if let review = host.model.taskReview, review.id == fixture.request.requestID, let staging = review.items.first(where: { $0.id == fixture.itemID })?.staging { return staging }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StagingHostFailure(description: "review did not produce a staging item: \(host.model.reviewError ?? "none")")
}
@MainActor private func stagingHostAllowed(_ host: HostController, _ fixture: StagingHostFixture) async throws -> StagingCleanupToken {
    let item = try await stagingHostReview(host, fixture)
    switch item.disposition {
    case .cleanupAllowed(let token): return token
    case .legacyEvidenceOnly(let reason), .retainedForReview(let reason): throw StagingHostFailure(description: "cleanup unexpectedly unavailable: \(reason)")
    }
}
@MainActor private func stagingHostWaitCleanup(_ host: HostController) async throws {
    for _ in 0..<300 { if !host.model.isCleaningStaging { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    throw StagingHostFailure(description: "queued staging cleanup did not finish")
}
@MainActor private func stagingHostRelease(_ host: inout HostController?) async throws {
    weak var prior = host; defer { prior = nil }; host = nil
    for _ in 0..<200 { if prior == nil { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    throw StagingHostFailure(description: "fixture host did not release its private ledger")
}
