import Foundation
import RightMouseCore

private struct RetentionCheckFailure: Error, CustomStringConvertible { let description: String }

@MainActor func runRetentionChecks() async throws -> Int {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-retention-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = SharedPaths(root: root.appendingPathComponent("state")); try paths.prepare()
    let ledger = try CommandLedger(directory: paths.operationsDirectory.appendingPathComponent("Commands"))
    let followups = TaskFollowupStore(directory: paths.operationsDirectory.appendingPathComponent("Followups"))
    let transfers = paths.operationsDirectory.appendingPathComponent("Transfers")
    let userDirectory = root.appendingPathComponent("user-files")
    let destination = userDirectory.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000), cutoff = now.addingTimeInterval(-30 * 86400), old = cutoff.addingTimeInterval(-1)
    var count = 0
    func check(_ test: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try test() else { throw RetentionCheckFailure(description: message) }; count += 1; print("PASS retention: \(message)")
    }
    for split in [false, true] {
        let shared = root.appendingPathComponent(split ? "fresh-shared" : "fresh-single")
        let fresh = SharedPaths(root: shared, privateRoot: split ? root.appendingPathComponent("fresh-private") : nil)
        try fresh.prepare()
        let freshLedger = try CommandLedger(directory: fresh.operationsDirectory.appendingPathComponent("Commands"))
        let empty = OperationRetention(paths: fresh, ledger: freshLedger).prune(now: now)
        try check(empty.scannedRequests == 0 && empty.removedRecords == 0 && empty.issues == 0, "fresh \(split ? "split" : "single") layout without optional operation directories has no recovery issue")
    }
    func receiptURL(_ id: UUID) -> URL { paths.receiptsDirectory.appendingPathComponent(id.uuidString + ".json") }
    func save(_ entry: LedgerEntry) throws { try ledger.save(entry); try PrivateFileIO.write(WireCodec.encoder().encode(entry.receipt), to: receiptURL(entry.request.requestID)) }
    func readRequest(at date: Date, status: ReceiptStatus = .completed, action: CommandAction = .copyText(format: .path)) throws -> CommandRequest {
        let request = CommandRequest(context: ActionContext(entryPoint: .items, container: nil, selection: [FileReference(url: userDirectory.appendingPathComponent("text.txt"))]), action: action, now: date)
        var entry = try ledger.accept(request, now: date).entry
        entry.receipt.status = status; entry.receipt.updatedAt = date; try save(entry); return request
    }
    func transfer(at date: Date) async throws -> (CommandRequest, TaskFollowupRecord) {
        let source = userDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("user bytes must survive".utf8).write(to: source)
        let request = CommandRequest(context: ActionContext(entryPoint: .items, container: FileReference(url: userDirectory, kindHint: .directory), selection: [FileReference(url: source)]), action: .transfer(mode: .copy, destination: FileReference(url: destination, kindHint: .directory), conflictPolicy: .skip), now: date)
        var entry = try ledger.accept(request, now: date).entry
        let result = await FileTransferEngine(journalDirectory: transfers).transfer(sources: [source], to: destination, mode: .copy, operationID: request.requestID)
        guard result.completedCount == 1 else { throw RetentionCheckFailure(description: "transfer fixture failed") }
        entry.receipt.status = .completed; entry.receipt.updatedAt = date
        entry.receipt.itemResults = result.items.map { ItemReceipt(itemID: $0.itemID, status: "success", destinationURL: $0.destination) }
        try save(entry)
        var followup = TaskFollowupRecord(requestID: request.requestID, destination: destination); followup.result = result; try followups.save(followup)
        return (request, followup)
    }
    let expired = try readRequest(at: old), boundary = try readRequest(at: cutoff), recent = try readRequest(at: cutoff.addingTimeInterval(1))
    let oldStage = try readRequest(at: old, action: .stageMove)
    let failedCreate = try readRequest(at: old, status: .failed, action: .createFile(templateID: "txt", destination: FileReference(url: destination), name: "not-created.txt"))
    let errorPinned = try readRequest(at: old, status: .failed)
    var errorEntry = try ledger.entry(errorPinned.requestID)!
    errorEntry.receipt.error = CommandFailure(.recoveryRequired, "uncertain result"); try save(errorEntry)
    let itemErrorPinned = try readRequest(at: old, status: .failed)
    var itemErrorEntry = try ledger.entry(itemErrorPinned.requestID)!
    itemErrorEntry.receipt.itemResults = [ItemReceipt(status: "failed", error: CommandFailure(.sourceRetained, "source retained"))]; try save(itemErrorEntry)
    var pinned: [CommandRequest] = []
    for status in [ReceiptStatus.accepted, .planning, .running, .waitingForUser, .cancelling, .needsReview] { pinned.append(try readRequest(at: old, status: status)) }
    let (complete, completeRecord) = try await transfer(at: old)
    let legacyJournalURL = transfers.appendingPathComponent(completeRecord.result!.items[0].itemID.uuidString + ".json")
    var legacyJournalObject = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyJournalURL)) as! [String: Any]
    legacyJournalObject.removeValue(forKey: "sourceCleanupURL")
    legacyJournalObject.removeValue(forKey: "sourceCleanupState")
    try PrivateFileIO.write(JSONSerialization.data(withJSONObject: legacyJournalObject, options: [.sortedKeys]), to: legacyJournalURL)
    let source = completeRecord.result!.items[0].source, copied = completeRecord.result!.items[0].destination!
    let sentinel = destination.appendingPathComponent(".rightmouse-unrelated-staging")
    try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: false)
    try Data("staging sentinel".utf8).write(to: sentinel.appendingPathComponent("payload"))
    let (uncertain, initialUndo) = try await transfer(at: old)
    var uncertainUndo = initialUndo; uncertainUndo.undoStarted = [initialUndo.result!.items[0].itemID]; try followups.save(uncertainUndo)
    let retainedSource = try readRequest(at: old, status: .partial)
    var retainedEntry = try ledger.entry(retainedSource.requestID)!
    retainedEntry.receipt.itemResults = [ItemReceipt(status: "sourceRetained")]; try save(retainedEntry)
    let (parent, firstRecord) = try await transfer(at: old), (child, _) = try await transfer(at: now)
    var parentRecord = firstRecord; parentRecord.retryRequestID = child.requestID; try followups.save(parentRecord)
    let (oldParent, secondRecord) = try await transfer(at: old), (oldChild, _) = try await transfer(at: old)
    var oldParentRecord = secondRecord; oldParentRecord.retryRequestID = oldChild.requestID; try followups.save(oldParentRecord)
    let (missingChildParent, thirdRecord) = try await transfer(at: old)
    var missingRecord = thirdRecord; missingRecord.retryRequestID = UUID(); try followups.save(missingRecord)
    let (badSidecar, sidecarWithBadResult) = try await transfer(at: old)
    var inconsistentSidecar = sidecarWithBadResult; inconsistentSidecar.result = nil
    try followups.save(inconsistentSidecar)
    let (missingSidecar, _) = try await transfer(at: old)
    try FileManager.default.removeItem(at: followups.directory.appendingPathComponent(missingSidecar.requestID.uuidString + ".json"))
    let (staged, stagedRecord) = try await transfer(at: old)
    let stagedJournalURL = transfers.appendingPathComponent(stagedRecord.result!.items[0].itemID.uuidString + ".json")
    var stagedJournal = try JSONDecoder().decode(TransferJournalRecord.self, from: Data(contentsOf: stagedJournalURL))
    stagedJournal.stagingURL = sentinel.appendingPathComponent("payload")
    try PrivateFileIO.write(JSONEncoder().encode(stagedJournal), to: stagedJournalURL)
    // Keep an otherwise completely eligible retry component when only one
    // member retains source-isolation evidence. Retention must never inspect
    // or mutate any of the user payload locations encoded in that evidence.
    let (isolatedParent, isolatedParentRecord) = try await transfer(at: old)
    let (isolatedChild, isolatedChildRecord) = try await transfer(at: old)
    var linkedIsolation = isolatedParentRecord; linkedIsolation.retryRequestID = isolatedChild.requestID
    try followups.save(linkedIsolation)
    let isolatedItem = isolatedChildRecord.result!.items[0]
    let quarantine = userDirectory.appendingPathComponent(".rightmouse-source-isolation-" + isolatedItem.itemID.uuidString)
    let quarantineBytes = Data("isolated original source evidence".utf8)
    try quarantineBytes.write(to: quarantine)
    let isolationJournalURL = transfers.appendingPathComponent(isolatedItem.itemID.uuidString + ".json")
    var isolationObject = try JSONSerialization.jsonObject(with: Data(contentsOf: isolationJournalURL)) as! [String: Any]
    isolationObject["sourceCleanupURL"] = quarantine.absoluteString
    try PrivateFileIO.write(JSONSerialization.data(withJSONObject: isolationObject, options: [.sortedKeys]), to: isolationJournalURL)
    let isolatedEvidenceURLs = [isolatedParent, isolatedChild].flatMap { request in
        [ledger.directory.appendingPathComponent(request.requestID.uuidString + ".json"), receiptURL(request.requestID), followups.directory.appendingPathComponent(request.requestID.uuidString + ".json")]
    } + [transfers.appendingPathComponent(isolatedParentRecord.result!.items[0].itemID.uuidString + ".json"), isolationJournalURL]
    let isolatedEvidenceBytes = try isolatedEvidenceURLs.map { try Data(contentsOf: $0) }
    var uncertainSourceCleanups: [(UUID, URL, Data)] = []
    for state in [SourceCleanupState.isolating, .isolated, .needsReview] {
        let (request, followup) = try await transfer(at: old)
        let journalURL = transfers.appendingPathComponent(followup.result!.items[0].itemID.uuidString + ".json")
        var journal = try JSONDecoder().decode(TransferJournalRecord.self, from: Data(contentsOf: journalURL))
        journal.sourceCleanupState = state
        try PrivateFileIO.write(JSONEncoder().encode(journal), to: journalURL)
        uncertainSourceCleanups.append((request.requestID, journalURL, try Data(contentsOf: journalURL)))
    }
    let (sourceCleanupComplete, completedCleanupRecord) = try await transfer(at: old)
    let completedCleanupURL = transfers.appendingPathComponent(completedCleanupRecord.result!.items[0].itemID.uuidString + ".json")
    var completedCleanupJournal = try JSONDecoder().decode(TransferJournalRecord.self, from: Data(contentsOf: completedCleanupURL))
    completedCleanupJournal.sourceCleanupState = .completed
    try PrivateFileIO.write(JSONEncoder().encode(completedCleanupJournal), to: completedCleanupURL)
    let (damagedJournal, damagedRecord) = try await transfer(at: old)
    try PrivateFileIO.write(Data("broken journal".utf8), to: transfers.appendingPathComponent(damagedRecord.result!.items[0].itemID.uuidString + ".json"))
    let (extraJournal, _) = try await transfer(at: old)
    try PrivateFileIO.write(JSONSerialization.data(withJSONObject: ["schemaVersion": 999, "operationID": extraJournal.requestID.uuidString]), to: transfers.appendingPathComponent(UUID().uuidString + ".json"))
    let brokenID = UUID(); let brokenURL = ledger.directory.appendingPathComponent(brokenID.uuidString + ".json")
    try PrivateFileIO.write(Data("bad ledger".utf8), to: brokenURL)
    let symlinked = try readRequest(at: old)
    let external = userDirectory.appendingPathComponent("external-record.json")
    try FileManager.default.moveItem(at: receiptURL(symlinked.requestID), to: external)
    let externalBytes = try Data(contentsOf: external)
    try FileManager.default.createSymbolicLink(at: receiptURL(symlinked.requestID), withDestinationURL: external)
    // Receipt state time governs age even when the record itself was just written.
    let report = OperationRetention(paths: paths, ledger: ledger).prune(now: now)
    try check(report.prunedRequests == 7, "only evidenced expired terminal requests are pruned")
    try check(try ledger.entry(oldStage.requestID) == nil, "expired stageMove dedupe record is removed after pending state lifetime")
    try check(try ledger.entry(failedCreate.requestID) == nil, "failed create with no item effects is eligible")
    try check(try ledger.entry(errorPinned.requestID) != nil, "recoveryRequired error pins a failed terminal receipt")
    try check(try ledger.entry(itemErrorPinned.requestID) != nil, "sourceRetained item error pins a failed terminal receipt")
    try check(try ledger.entry(expired.requestID) == nil, "older than 30 days is removed despite recent filesystem mtime")
    try check(try ledger.entry(boundary.requestID) != nil && ledger.entry(recent.requestID) != nil, "exact 30-day boundary and newer requests are retained")
    for request in pinned { try check(try ledger.entry(request.requestID) != nil, "nonterminal or needsReview \(request.requestID) is retained") }
    try check(try ledger.entry(uncertain.requestID) != nil && ledger.entry(retainedSource.requestID) != nil, "uncertain undo and sourceRetained survive age pruning")
    try check(try ledger.entry(parent.requestID) != nil && ledger.entry(child.requestID) != nil, "recent retry child pins its entire parent chain")
    try check(try ledger.entry(oldParent.requestID) == nil && ledger.entry(oldChild.requestID) == nil, "fully evidenced expired retry component is removed together")
    try check(try ledger.entry(missingChildParent.requestID) != nil, "missing retry child pins its parent")
    try check(try ledger.entry(badSidecar.requestID) != nil && ledger.entry(missingSidecar.requestID) != nil, "bad or missing followup evidence pins its task")
    try check(try ledger.entry(staged.requestID) != nil && ledger.entry(damagedJournal.requestID) != nil, "staging reference and malformed journal preserve recovery evidence")
    try check(try ledger.entry(isolatedParent.requestID) != nil && ledger.entry(isolatedChild.requestID) != nil, "source isolation reference pins its entire expired terminal retry component")
    try check(try isolatedEvidenceURLs.map { try Data(contentsOf: $0) } == isolatedEvidenceBytes, "source isolation keeps every parent/child command receipt followup and journal byte intact")
    try check(try Data(contentsOf: isolatedItem.source) == Data("user bytes must survive".utf8) && Data(contentsOf: isolatedItem.destination!) == Data("user bytes must survive".utf8) && Data(contentsOf: quarantine) == quarantineBytes, "retention leaves source isolated evidence and committed target payloads untouched")
    try check(try ledger.entry(complete.requestID) == nil && !FileManager.default.fileExists(atPath: legacyJournalURL.path), "legacy journal without source cleanup fields remains eligible for ordinary terminal pruning")
    for (id, journalURL, bytes) in uncertainSourceCleanups {
        try check(try ledger.entry(id) != nil && Data(contentsOf: journalURL) == bytes, "uncertain source cleanup state without a URL preserves terminal evidence")
    }
    try check(try ledger.entry(sourceCleanupComplete.requestID) == nil && !FileManager.default.fileExists(atPath: completedCleanupURL.path), "completed source cleanup without retained references permits ordinary terminal pruning")
    try check(try ledger.entry(extraJournal.requestID) != nil, "invalid additional journal with known operation ID pins its complete task")
    try check(try Data(contentsOf: brokenURL) == Data("bad ledger".utf8) && report.issues > 0, "isolated malformed ledger is preserved without blocking unrelated cleanup")
    try check(try FileManager.default.destinationOfSymbolicLink(atPath: receiptURL(symlinked.requestID).path) == external.path && Data(contentsOf: external) == externalBytes, "symlink and external target remain untouched")
    try check(try Data(contentsOf: source) == Data("user bytes must survive".utf8) && Data(contentsOf: copied) == Data(contentsOf: source), "cleanup never deletes user source or destination")
    try check(try Data(contentsOf: sentinel.appendingPathComponent("payload")) == Data("staging sentinel".utf8), "cleanup never visits or deletes user staging content")
    try check(!FileManager.default.fileExists(atPath: followups.directory.appendingPathComponent(complete.requestID.uuidString + ".json").path) && !FileManager.default.fileExists(atPath: transfers.appendingPathComponent(completeRecord.result!.items[0].itemID.uuidString + ".json").path), "complete transfer sidecar and journal are pruned")
    do { _ = try ledger.accept(expired, now: now); throw RetentionCheckFailure(description: "expired request was accepted after retention") }
    catch let failure as CommandFailure { try check(failure.code == .requestExpired, "expired duplicate remains rejected after its dedupe record is removed") }
    let repeated = OperationRetention(paths: paths, ledger: ledger).prune(now: now)
    try check(repeated.prunedRequests == 0, "repeating startup cleanup does not replay or remove protected work")
    let wrong = OperationRetention(paths: SharedPaths(root: root.appendingPathComponent("wrong")), ledger: ledger).prune(now: now)
    try check(wrong.removedRecords == 0 && wrong.issues == 1, "ledger-directory mismatch prevents pruning")
    let reviews = paths.operationsDirectory.appendingPathComponent("Reviews")
    try FileManager.default.createSymbolicLink(at: reviews, withDestinationURL: userDirectory)
    let directorySymlink = OperationRetention(paths: paths, ledger: ledger).prune(now: now)
    try check(directorySymlink.removedRecords == 0 && directorySymlink.issues > 0 && (try FileManager.default.destinationOfSymbolicLink(atPath: reviews.path)) == userDirectory.path, "private-directory symlink is rejected without following or deleting it")
    // Unknown sidecars make the retry graph untrustworthy, even for an unrelated
    // read request. Each variant uses a new eligible candidate after the block.
    try FileManager.default.removeItem(at: reviews)
    for corruption in ["decode", "schema", "identity"] {
        let candidate = try readRequest(at: old)
        let id = UUID()
        let filenameID = corruption == "identity" ? UUID() : id
        let url = followups.directory.appendingPathComponent(filenameID.uuidString + ".json")
        var record = TaskFollowupRecord(requestID: id)
        if corruption == "schema" { record.schemaVersion = 999 }
        let bytes = corruption == "decode" ? Data("broken".utf8) : try WireCodec.encoder().encode(record)
        // Only the identity case has a mismatched filename; schema is isolated.
        try PrivateFileIO.write(bytes, to: url)
        let blocked = OperationRetention(paths: paths, ledger: ledger).prune(now: now)
        try check(blocked.removedRecords == 0 && blocked.issues > 0 && (try ledger.entry(candidate.requestID)) != nil, "unknown followup \(corruption) blocks the entire cleanup pass")
        try FileManager.default.removeItem(at: url)
        let resumed = OperationRetention(paths: paths, ledger: ledger).prune(now: now)
        try check(resumed.prunedRequests == 1 && (try ledger.entry(candidate.requestID)) == nil, "removing unknown followup \(corruption) allows unrelated expired cleanup")
    }
    // A two-member complete copy chain has eight records. Interrupt after each
    // of the seven positions that can leave Commands behind, then run again.
    for stopAfter in 1...7 {
        let isolated = SharedPaths(root: root.appendingPathComponent("interruption-\(stopAfter)")); try isolated.prepare()
        let isolatedLedger = try CommandLedger(directory: isolated.operationsDirectory.appendingPathComponent("Commands"))
        let store = TaskFollowupStore(directory: isolated.operationsDirectory.appendingPathComponent("Followups"))
        var ids: [UUID] = [], records: [TaskFollowupRecord] = []
        for _ in 0..<2 {
            let original = try await transfer(at: old)
            let entry = try ledger.entry(original.0.requestID)!
            try isolatedLedger.save(entry)
            try PrivateFileIO.write(WireCodec.encoder().encode(entry.receipt), to: isolated.receiptsDirectory.appendingPathComponent(original.0.requestID.uuidString + ".json"))
            try store.save(original.1)
            let journalName = original.1.result!.items[0].itemID.uuidString + ".json"
            try PrivateFileIO.write(Data(contentsOf: transfers.appendingPathComponent(journalName)), to: isolated.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(journalName))
            ids.append(original.0.requestID); records.append(original.1)
        }
        records[0].retryRequestID = ids[1]; try store.save(records[0])
        var removed = 0, edgeOrderSafe = true
        let interrupted = OperationRetention(paths: isolated, ledger: isolatedLedger, afterRemoval: { phase in
            removed += 1
            if phase == .retryLinks {
                edgeOrderSafe = edgeOrderSafe && ids.allSatisfy { !FileManager.default.fileExists(atPath: isolated.receiptsDirectory.appendingPathComponent($0.uuidString + ".json").path) }
            }
            if removed == stopAfter { throw RetentionCheckFailure(description: "simulated interruption") }
        }).prune(now: now)
        let remaining = try ids.filter { try isolatedLedger.entry($0) != nil }
        try check(interrupted.removedRecords == stopAfter && interrupted.issues > 0 && !remaining.isEmpty, "interruption \(stopAfter): hook stops after the requested deletion while Commands remain")
        let recovered = OperationRetention(paths: isolated, ledger: isolatedLedger).prune(now: now)
        try check(recovered.removedRecords == 0 && (try remaining.allSatisfy { try isolatedLedger.entry($0) != nil }), "interruption \(stopAfter): next startup preserves every remaining member")
        try check(edgeOrderSafe, "interruption \(stopAfter): retry edge is never deleted before all member receipts")
    }
    return count
}
