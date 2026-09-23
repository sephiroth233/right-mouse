import Foundation
import CryptoKit
import Darwin
import RightMouseCore

struct RetentionReport {
    var scannedRequests = 0
    var prunedRequests = 0
    var removedRecords = 0
    var retainedRequests = 0
    var issues = 0
    var prunedIDs = Set<UUID>()
}

/// Run synchronously while the host is idle, using its already locked ledger.
/// This only unlinks validated private JSON records; payload URLs are never accessed.
struct OperationRetention {
    enum RemovalPhase { case evidence, retryLinks, commands }
    let paths: SharedPaths
    let ledger: CommandLedger
    private let afterRemoval: ((RemovalPhase) throws -> Void)?
    init(paths: SharedPaths, ledger: CommandLedger, lifetime: TimeInterval = 30 * 24 * 60 * 60, afterRemoval: ((RemovalPhase) throws -> Void)? = nil) {
        self.paths = paths; self.ledger = ledger; self.lifetime = lifetime; self.afterRemoval = afterRemoval
    }
    private let lifetime: TimeInterval

    func prune(now: Date = Date()) -> RetentionReport {
        var report = RetentionReport()
        do {
            // URL's directory hint can differ when Commands is constructed before
            // first creation. Compare normalized filesystem paths, then validate the
            // same root/descendants below with no-follow descriptors and ownership.
            guard ledger.directory.isFileURL,
                  ledger.directory.standardizedFileURL.path == paths.operationsDirectory.appendingPathComponent("Commands").standardizedFileURL.path else { throw RetentionFailure.invalid }
            let root = try RetentionDirectory(absolute: paths.root)
            let privateRoot = try RetentionDirectory(absolute: paths.privateRoot)
            let operations = try privateRoot.child("Operations")
            let commands = try operations.child("Commands")
            let receipts = try root.child("Receipts")
            var directories: [String: RetentionDirectory] = ["Commands": commands, "Receipts": receipts]
            for name in ["Inbox"] { if let value = try root.optionalChild(name) { directories[name] = value } }
            for name in ["Followups", "Transfers", "Reviews"] { if let value = try operations.optionalChild(name) { directories[name] = value } }
            var entries: [UUID: (LedgerEntry, RetentionFile)] = [:]
            for name in try commands.names() where name.hasSuffix(".json") {
                report.scannedRequests += 1
                do {
                    let file = try commands.read(name)
                    let value = try WireCodec.decoder().decode(LedgerEntry.self, from: file.data)
                    guard name == value.request.requestID.uuidString + ".json", value.schemaVersion == 1,
                          value.request.schemaVersion == 1, value.receipt.schemaVersion == 1,
                          value.receipt.requestID == value.request.requestID,
                          value.digest == SHA256.hash(data: try WireCodec.encoder().encode(value.request)).map({ String(format: "%02x", $0) }).joined() else { throw RetentionFailure.invalid }
                    entries[value.request.requestID] = (value, file)
                } catch { report.issues += 1 }
            }
            // Build undirected retry components; any missing/ineligible member pins its chain.
            var links: [UUID: Set<UUID>] = [:]
            var retryParents = Set<UUID>()
            if let followups = directories["Followups"] {
                for name in try followups.names() where name.hasSuffix(".json") {
                    // An unknown sidecar may contain the only edge to an otherwise
                    // eligible child. Never prune with an incomplete retry graph.
                    let file = try followups.read(name)
                    let record = try WireCodec.decoder().decode(TaskFollowupRecord.self, from: file.data)
                    guard record.schemaVersion == 1, name == record.requestID.uuidString + ".json" else { throw RetentionFailure.invalid }
                    if let child = record.retryRequestID {
                        retryParents.insert(record.requestID)
                        links[record.requestID, default: []].insert(child)
                        links[child, default: []].insert(record.requestID)
                    }
                }
            }
            var journals: [UUID: [(TransferJournalRecord, RetentionFile)]] = [:]
            var invalidJournalOperations = Set<UUID>()
            if let transfers = directories["Transfers"] {
                for name in try transfers.names() where name.hasSuffix(".json") {
                    var knownOperation: UUID?
                    do {
                        let file = try transfers.read(name)
                        if let object = try JSONSerialization.jsonObject(with: file.data) as? [String: Any], let text = object["operationID"] as? String { knownOperation = UUID(uuidString: text) }
                        let record = try JSONDecoder().decode(TransferJournalRecord.self, from: file.data)
                        guard name == record.itemID.uuidString + ".json", record.schemaVersion == 1 else { throw RetentionFailure.invalid }
                        journals[record.operationID, default: []].append((record, file))
                    } catch { if let knownOperation { invalidJournalOperations.insert(knownOperation) }; report.issues += 1 }
                }
            }
            let cutoff = now.addingTimeInterval(-lifetime)
            var plans: [UUID: [(RetentionDirectory, RetentionFile)]] = [:]
            let terminal: Set<ReceiptStatus> = [.completed, .partial, .failed, .cancelled, .rejected]
            for (id, pair) in entries {
                let (entry, commandFile) = pair
                guard terminal.contains(entry.receipt.status), !invalidJournalOperations.contains(id), entry.receipt.updatedAt < cutoff,
                      entry.request.createdAt < cutoff, entry.request.expiresAt <= now,
                      ![CommandErrorCode.recoveryRequired, .sourceRetained].contains(entry.receipt.error?.code ?? .invalidRequest),
                      !entry.receipt.itemResults.contains(where: { [.recoveryRequired, .sourceRetained].contains($0.error?.code ?? .invalidRequest) }),
                      !entry.receipt.itemResults.contains(where: { ["sourceRetained", "needsReview"].contains($0.status) }) else { continue }
                do {
                    var files: [(RetentionDirectory, RetentionFile)] = []
                    let receiptFile = try receipts.read(id.uuidString + ".json")
                    let receipt = try WireCodec.decoder().decode(CommandReceipt.self, from: receiptFile.data)
                    guard try WireCodec.encoder().encode(receipt) == WireCodec.encoder().encode(entry.receipt) else { throw RetentionFailure.invalid }
                    files.append((receipts, receiptFile))
                    for name in ["Inbox", "Reviews"] {
                        guard let directory = directories[name], let file = try directory.optionalRead(id.uuidString + ".json") else { continue }
                        if name == "Inbox" {
                            let request = try RequestValidator.decode(file.data)
                            guard try WireCodec.encoder().encode(request) == WireCodec.encoder().encode(entry.request) else { throw RetentionFailure.invalid }
                        } else {
                            let review = try WireCodec.decoder().decode(RetentionReview.self, from: file.data)
                            guard review.schemaVersion == 1, review.requestID == id, review.confirmedAt < cutoff else { throw RetentionFailure.invalid }
                        }
                        files.append((directory, file))
                    }
                    let followupFile = try directories["Followups"]?.optionalRead(id.uuidString + ".json")
                    switch entry.request.action {
                    case .transfer, .pasteMove:
                        guard let directory = directories["Followups"], let file = followupFile,
                              let transfers = directories["Transfers"] else { throw RetentionFailure.invalid }
                        let followup = try WireCodec.decoder().decode(TaskFollowupRecord.self, from: file.data)
                        guard followup.schemaVersion == 1, followup.requestID == id,
                              followup.undoStarted.isEmpty, followup.undoCompleted.isEmpty,
                              let result = followup.result, result.operationID == id,
                              result.state == entry.receipt.status.rawValue, !result.items.isEmpty,
                              Set(result.items.map(\.itemID)).count == result.items.count,
                              result.items.count == entry.receipt.itemResults.count else { throw RetentionFailure.invalid }
                        let expectedMode: TransferMode
                        if case let .transfer(mode, _, _) = entry.request.action { expectedMode = mode == .copy ? .copy : .move } else { expectedMode = .move }
                        guard followup.destination.map(local) ?? true,
                              Set(entry.receipt.itemResults.map(\.itemID)).count == entry.receipt.itemResults.count else { throw RetentionFailure.invalid }
                        let records = journals[id] ?? []
                        guard records.count == result.items.count else { throw RetentionFailure.invalid }
                        for item in result.items {
                            guard ![.needsReview, .sourceRetained].contains(item.status), item.operationID == nil || item.operationID == id,
                                  let itemReceipt = entry.receipt.itemResults.first(where: { $0.itemID == item.itemID }),
                                  itemReceipt.status == (item.status == .completed ? "success" : item.status.rawValue), itemReceipt.destinationURL == item.destination,
                                  let (journal, journalFile) = records.first(where: { $0.0.itemID == item.itemID }),
                                  journal.phase == item.status.rawValue, journal.source == item.source, journal.mode == expectedMode,
                                  try journal.result.map({ try WireCodec.encoder().encode($0) }) == WireCodec.encoder().encode(item),
                                  local(item.source), item.destination.map(local) ?? true,
                                  journal.stagingURL == nil, journal.sourceCleanupURL == nil,
                                  journal.sourceCleanupIdentity == nil, journal.sourceCleanupContainerIdentity == nil,
                                  journal.sourceCleanupState == nil || journal.sourceCleanupState == .completed else { throw RetentionFailure.invalid }
                            if let destination = item.destination { guard journal.destination == destination else { throw RetentionFailure.invalid } }
                            if let undo = item.undoToken {
                                guard local(undo.originalURL), local(undo.currentURL), undo.originalURL == item.source, undo.currentURL == item.destination else { throw RetentionFailure.invalid }
                            }
                            files.append((transfers, journalFile))
                        }
                        files.append((directory, file))
                    case .createFile:
                        guard followupFile == nil, (journals[id] ?? []).isEmpty else { throw RetentionFailure.invalid }
                        if entry.receipt.status == .completed {
                            guard entry.receipt.itemResults.count == 1, entry.receipt.itemResults[0].status == "success",
                                  entry.receipt.itemResults[0].destinationURL.map(local) == true else { throw RetentionFailure.invalid }
                        } else {
                            guard [.failed, .cancelled, .rejected].contains(entry.receipt.status), entry.receipt.itemResults.isEmpty else { throw RetentionFailure.invalid }
                        }
                    case .copyText, .openFavorite, .openWith, .stageMove:
                        guard followupFile == nil, (journals[id] ?? []).isEmpty, entry.receipt.itemResults.isEmpty else { throw RetentionFailure.invalid }
                    }
                    files.append((commands, commandFile)) // Commit removal last; interruption leaves conservative recovery evidence.
                    plans[id] = files
                } catch { report.issues += 1 }
            }
            var visited = Set<UUID>()
            for id in entries.keys where !visited.contains(id) {
                var component = Set<UUID>(), pending = [id]
                while let member = pending.popLast() {
                    if component.insert(member).inserted { pending.append(contentsOf: links[member] ?? []) }
                }
                visited.formUnion(component)
                guard component.allSatisfy({ plans[$0] != nil }) else { continue }
                do {
                    let all = component.flatMap { plans[$0]! }
                    for (directory, file) in all { try directory.verify(file) }
                    func rank(_ record: (RetentionDirectory, RetentionFile)) -> Int {
                        if record.0 === commands { return 2 }
                        if record.0 === directories["Followups"], let id = UUID(uuidString: String(record.1.name.dropLast(5))), retryParents.contains(id) { return 1 }
                        return 0
                    }
                    // Remove every member's eligibility evidence before removing any
                    // one-way retry edge. After interruption, a disconnected member
                    // lacks its receipt and cannot become an eligible singleton.
                    for record in all.sorted(by: { rank($0) < rank($1) }) {
                        try record.0.remove(record.1); report.removedRecords += 1
                        let phase: RemovalPhase = rank(record) == 0 ? .evidence : (rank(record) == 1 ? .retryLinks : .commands)
                        try afterRemoval?(phase)
                    }
                    report.prunedRequests += component.count
                    report.prunedIDs.formUnion(component)
                } catch { report.issues += 1 }
            }
        } catch { report.issues += 1 }
        report.retainedRequests = report.scannedRequests - report.prunedRequests
        return report
    }
    private func local(_ url: URL) -> Bool { url.isFileURL && (url.host ?? "").isEmpty && url.query == nil && url.fragment == nil && !url.path.contains("\0") }
}

private struct RetentionReview: Decodable { let schemaVersion: Int; let requestID: UUID; let confirmedAt: Date }
private enum RetentionFailure: Error { case invalid }
private struct RetentionFile { let name: String; let data: Data; let device: dev_t; let inode: ino_t; let modifiedAt: Date }

/// Directory descriptors anchor all reads/unlinks even if a pathname is replaced.
private final class RetentionDirectory {
    let descriptor: Int32
    init(descriptor: Int32) throws {
        var info = stat()
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(descriptor); throw RetentionFailure.invalid }
        self.descriptor = descriptor
    }
    convenience init(absolute url: URL) throws {
        // Reject symlink components instead of following an untrusted root alias.
        guard url.isFileURL, url.path.hasPrefix("/") else { throw RetentionFailure.invalid }
        // Foundation can preserve /var or /tmp aliases. Resolve only the already
        // prepared application root with Darwin, then forbid symlinks below it.
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              let physical = realpath(url.path, nil) else { throw RetentionFailure.invalid }
        defer { free(physical) }
        let physicalComponents = String(cString: physical).split(separator: "/").map(String.init)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw RetentionFailure.invalid }
        for component in physicalComponents {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(current); current = next
            guard current >= 0 else { throw RetentionFailure.invalid }
        }
        try self.init(descriptor: current)
    }
    deinit { close(descriptor) }
    func child(_ name: String) throws -> RetentionDirectory { try RetentionDirectory(descriptor: openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)) }
    func optionalChild(_ name: String) throws -> RetentionDirectory? {
        let value = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if value < 0 && errno == ENOENT { return nil }
        return try RetentionDirectory(descriptor: value)
    }
    func names() throws -> [String] {
        guard let stream = fdopendir(dup(descriptor)) else { throw RetentionFailure.invalid }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
    func optionalRead(_ name: String) throws -> RetentionFile? {
        do { return try read(name) } catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    func read(_ name: String) throws -> RetentionFile {
        guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil, !name.contains("/") else { throw RetentionFailure.invalid }
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= 8 * RequestValidator.maximumBytes else { throw RetentionFailure.invalid }
        let data = try handle.read(upToCount: 8 * RequestValidator.maximumBytes + 1) ?? Data()
        guard data.count == info.st_size else { throw RetentionFailure.invalid }
        return RetentionFile(name: name, data: data, device: info.st_dev, inode: info.st_ino, modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
    }
    func verify(_ file: RetentionFile) throws {
        let current = try read(file.name)
        guard current.device == file.device, current.inode == file.inode, current.data == file.data, current.modifiedAt == file.modifiedAt else { throw RetentionFailure.invalid }
    }
    func remove(_ file: RetentionFile) throws {
        try verify(file)
        guard unlinkat(descriptor, file.name, 0) == 0 else { throw RetentionFailure.invalid }
        guard fsync(descriptor) == 0 else { throw RetentionFailure.invalid }
    }
}
