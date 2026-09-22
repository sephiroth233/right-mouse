import Foundation
import Darwin

public actor FileTransferEngine {
    let journalDirectory: URL
    var running = false
    private var journalFailed = false
    private var ownedStaging: [URL: TransferFileIdentity] = [:]
    // Deterministic fault injection for fixture tests; production always uses volume identity.
    var forceCrossVolumeForTesting = false
    var phaseHookForTesting: ((String, URL, URL) throws -> Void)?
    func configureTesting(forceCrossVolume: Bool = false, phaseHook: ((String, URL, URL) throws -> Void)? = nil) {
        forceCrossVolumeForTesting = forceCrossVolume; phaseHookForTesting = phaseHook
    }

    public init(journalDirectory: URL) { self.journalDirectory = journalDirectory }

    public func transfer(sources: [URL], to target: URL, mode: TransferMode,
                         conflictPolicy: TransferConflictPolicy = .ask,
                         cancellation: TransferCancellation = TransferCancellation(),
                         onProgress: (@Sendable (TransferProgress) -> Void)? = nil,
                         resolveConflict: (@Sendable (URL, URL) async -> TransferConflictDecision)? = nil,
                         operationID: UUID = UUID()) async -> TransferResult {
        guard !running else {
            let failure = CommandFailure(.ioFailed, "另一个文件操作正在进行，请稍后重试。", retryable: true)
            return TransferResult(operationID: operationID, items: sources.map { .init(operationID: operationID, source: $0, status: .failed, message: failure.message, failure: failure) })
        }
        running = true
        journalFailed = false
        defer { running = false }
        var results: [TransferItemResult] = []
        let resolvedTarget = target.resolvingSymlinksInPath()
        let destinationDirectory: URL
        if let physical = realpath(resolvedTarget.path, nil) {
            destinationDirectory = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            free(physical)
        } else { destinationDirectory = resolvedTarget }
        let targetIdentity: TransferFileIdentity
        do { targetIdentity = try TransferFileSystem.identity(destinationDirectory) }
        catch {
            let failure = TransferFailureMapping.failure(for: error, context: .destination)
            return TransferResult(operationID: operationID, items: sources.map { .init(operationID: operationID, source: $0, status: .failed, message: failure.message, failure: failure) })
        }
        do {
            guard !sources.isEmpty, sources.count <= 1024, target.isFileURL,
                  targetIdentity.kind == S_IFDIR else { throw TransferEngineError.invalidTarget }
            try PrivateFileIO.ensureDirectory(journalDirectory)
            for rawSource in sources {
                if !rawSource.isFileURL {
                    let failure = TransferFailureMapping.failure(for: TransferEngineError.invalidSource)
                    results.append(.init(operationID: operationID, source: rawSource, status: .failed, message: failure.message, failure: failure))
                    continue
                }
                // Resolve parents, keeping the selected symbolic link itself intact.
                let source = rawSource.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(rawSource.lastPathComponent).standardizedFileURL
                let result = await transferOne(source: source, target: destinationDirectory, targetIdentity: targetIdentity, mode: mode, policy: conflictPolicy, cancellation: cancellation, operationID: operationID, completed: results.count, total: sources.count, onProgress: onProgress, resolveConflict: resolveConflict)
                results.append(result)
                onProgress?(TransferProgress(operationID: operationID, completedItems: results.count, totalItems: sources.count, phase: result.status.rawValue, bytesProcessed: 0))
            }
        } catch {
            let failure = TransferFailureMapping.failure(for: error)
            results = sources.map { .init(operationID: operationID, source: $0, status: .failed, message: failure.message, failure: failure) }
        }
        return TransferResult(operationID: operationID, items: results)
    }

    private func transferOne(source: URL, target: URL, targetIdentity: TransferFileIdentity, mode: TransferMode, policy: TransferConflictPolicy,
                             cancellation: TransferCancellation, operationID: UUID, completed: Int, total: Int,
                             onProgress: (@Sendable (TransferProgress) -> Void)?,
                             resolveConflict: (@Sendable (URL, URL) async -> TransferConflictDecision)?) async -> TransferItemResult {
        var destination = target.appendingPathComponent(source.lastPathComponent)
        var record = TransferJournalRecord(operationID: operationID, itemID: UUID(), source: source, destination: destination, mode: mode, phase: "planned")
        var committed = false
        var stagingContainer: URL?
        var sameVolume = false
        var sourceSnapshot: [String: TransferSnapshot]?
        var processed: Int64 = 0
        func progress(_ phase: String) {
            onProgress?(TransferProgress(operationID: operationID, completedItems: completed, totalItems: total, phase: phase, bytesProcessed: processed))
        }
        do {
            if journalFailed { cancellation.cancel() }
            try TransferFileSystem.check(cancellation)
            guard source.isFileURL, source.path != "/" else { throw TransferEngineError.invalidSource }
            let identity = try TransferFileSystem.identity(source)
            guard [UInt32(S_IFREG), UInt32(S_IFDIR), UInt32(S_IFLNK)].contains(identity.kind) else { throw TransferEngineError.unsupportedFile }
            if source == destination {
                return .init(itemID: record.itemID, operationID: operationID, source: source, destination: destination, status: .skipped, message: "来源与目标相同，未做更改。")
            }
            if identity.kind == S_IFDIR && (target.path == source.path || target.path.hasPrefix(source.path + "/")) { throw TransferEngineError.descendantTarget }
            record.sourceIdentity = identity
            try save(record)
            try checkTargetIdentity(target, expected: targetIdentity)
            if TransferFileSystem.exists(destination) {
                let decision = await decide(policy: policy, source: source, destination: destination, resolve: resolveConflict)
                try checkTargetIdentity(target, expected: targetIdentity)
                switch decision {
                case .skip: return try finish(&record, .init(itemID: record.itemID, operationID: operationID, source: source, destination: destination, status: .skipped, message: "目标同名，已跳过。"))
                case .cancel: cancellation.cancel(); throw TransferEngineError.cancelled
                case .keepBoth: destination = nextCandidate(source.lastPathComponent, in: target); record.destination = destination
                }
            }
            try TransferFileSystem.check(cancellation)
            try checkTargetIdentity(target, expected: targetIdentity)
            // A full manifest also rejects unsupported descendants before a same-volume move.
            progress("scanning")
            sourceSnapshot = try TransferFileSystem.manifest(source, cancellation: cancellation)
            guard sourceSnapshot?[""]?.identity == identity else { throw TransferEngineError.sourceChanged }
            sameVolume = identity.device == (try TransferFileSystem.identity(target)).device && !forceCrossVolumeForTesting
            let objectToCommit: URL
            if mode == .move && sameVolume {
                objectToCommit = source
            } else {
                let container = target.appendingPathComponent(".rightmouse-\(record.itemID.uuidString)", isDirectory: true)
                record.stagingURL = container; stagingContainer = container
                record.phase = "staging"; try save(record)
                guard mkdir(container.path, 0o700) == 0 else { throw TransferEngineError.system(errno) }
                let stagingIdentity = try TransferFileSystem.identity(container)
                ownedStaging[container] = stagingIdentity
                record.stagingIdentity = stagingIdentity
                record.stagingParentIdentity = targetIdentity
                // Ownership is durable before any payload is copied into staging.
                try save(record)
                let staged = container.appendingPathComponent("payload")
                progress("copying")
                try phaseHookForTesting?("beforeCopy", source, destination)
                try TransferFileSystem.copyTree(source, staged, cancellation: cancellation) { count in processed += count; progress("copying") }
                progress("verifying")
                let stagedSnapshot = try TransferFileSystem.manifest(staged, cancellation: cancellation)
                guard TransferFileSystem.equivalent(sourceSnapshot!, stagedSnapshot),
                      try TransferFileSystem.manifest(source, cancellation: cancellation) == sourceSnapshot else { throw TransferEngineError.verificationFailed }
                record.phase = "verified"; try save(record)
                objectToCommit = staged
            }
            while true {
                try TransferFileSystem.check(cancellation)
                guard try TransferFileSystem.manifest(source, cancellation: cancellation) == sourceSnapshot else { throw TransferEngineError.sourceChanged }
                record.destination = destination
                record.phase = "committing"; try save(record)
                try phaseHookForTesting?("beforeCommit", source, destination)
                do {
                    try TransferFileSystem.coordinateMutation(source: source, destination: destination) {
                        try checkTargetIdentity(target, expected: targetIdentity)
                        guard try TransferFileSystem.manifest(source, cancellation: cancellation) == sourceSnapshot else { throw TransferEngineError.sourceChanged }
                        try phaseHookForTesting?("immediatelyBeforeSourceRename", source, destination)
                        try TransferFileSystem.renameExclusive(objectToCommit, destination)
                        // The namespace mutation has happened even if coordination or a following
                        // validation reports an error. Status handling must preserve that fact.
                        committed = true
                        try phaseHookForTesting?("immediatelyAfterSourceRename", source, destination)
                    }
                    break
                } catch TransferEngineError.occupied {
                    let decision = await decide(policy: policy, source: source, destination: destination, resolve: resolveConflict)
                    try checkTargetIdentity(target, expected: targetIdentity)
                    switch decision {
                    case .skip:
                        try cleanStaging(stagingContainer)
                        record.stagingURL = nil
                        return try finish(&record, .init(itemID: record.itemID, operationID: operationID, source: source, destination: destination, status: .skipped, message: "提交时目标被占用，已跳过。"))
                    case .cancel: cancellation.cancel(); throw TransferEngineError.cancelled
                    case .keepBoth: destination = nextCandidate(source.lastPathComponent, in: target)
                    }
                }
            }
            try checkTargetIdentity(target, expected: targetIdentity)
            let committedManifest = try TransferFileSystem.manifest(destination, cancellation: cancellation)
            if mode == .move && sameVolume {
                guard TransferFileSystem.sameObjectsAfterRename(sourceSnapshot!, committedManifest) else {
                    throw TransferEngineError.sourceChanged
                }
            } else {
                guard TransferFileSystem.equivalent(sourceSnapshot!, committedManifest) else {
                    throw TransferEngineError.verificationFailed
                }
            }
            record.destinationIdentity = try TransferFileSystem.identity(destination)
            record.phase = "targetCommitted"; try save(record)
            try phaseHookForTesting?("afterCommit", source, destination)
            if mode == .move && !sameVolume {
                try TransferFileSystem.check(cancellation)
                // Recheck both copies after the target becomes visible. Changes retain the source.
                guard TransferFileSystem.equivalent(sourceSnapshot!, try TransferFileSystem.manifest(destination, cancellation: cancellation)),
                      try TransferFileSystem.manifest(source, cancellation: cancellation) == sourceSnapshot else { throw TransferEngineError.sourceChanged }
                record.phase = "sourceCleanupPending"; try save(record)
                try phaseHookForTesting?("beforeSourceCleanup", source, destination)
                progress("sourceCleanup")
                try isolateVerifyAndRemoveSource(source, target: destination, expected: sourceSnapshot!, targetIdentity: targetIdentity,
                                                 record: &record, cancellation: cancellation)
                record.phase = "sourceRemoved"; try save(record)
            }
            try cleanStaging(stagingContainer)
            record.stagingURL = nil
            let undo = mode == .move && sameVolume ? TransferUndoToken(originalURL: source, currentURL: destination, identity: try TransferFileSystem.identity(destination), contentFingerprint: try TransferFileSystem.fingerprint(TransferFileSystem.manifest(destination, cancellation: TransferCancellation()))) : nil
            return try finish(&record, .init(itemID: record.itemID, operationID: operationID, source: source, destination: destination, status: .completed, message: mode == .move ? "移动完成。" : "复制完成。", undoToken: undo))
        } catch {
            let status: TransferItemStatus
            if record.sourceCleanupURL != nil {
                status = .needsReview
            } else if committed {
                status = mode == .move && !sameVolume && TransferFileSystem.exists(source) ? .sourceRetained : .needsReview
            } else if let engineError = error as? TransferEngineError, case .cancelled = engineError { status = .cancelled }
            else { status = .failed }
            // Pre-commit staging is private to this item. Retain it whenever cleanup cannot be verified.
            if !committed {
                do { try cleanStaging(stagingContainer); record.stagingURL = nil }
                catch { /* Preserve the staging reference until ownership and cleanup can be verified. */ }
            }
            let failure = TransferFailureMapping.conservativeFailure(for: error, status: status, committed: committed)
            let result = TransferItemResult(itemID: record.itemID, operationID: operationID, source: source, destination: committed ? destination : nil, status: status,
                                            message: failure.message, failure: failure)
            do { return try finish(&record, result) }
            catch {
                let journalFailure = CommandFailure(.recoveryRequired, "操作记录写入失败，停止后续副作用。请核对来源和目标。")
                return .init(itemID: record.itemID, operationID: operationID, source: source, destination: committed ? destination : nil,
                             status: committed ? .needsReview : .failed, message: journalFailure.message, failure: journalFailure)
            }
        }
    }

    private func checkTargetIdentity(_ url: URL, expected: TransferFileIdentity) throws {
        let current: TransferFileIdentity
        do { current = try TransferFileSystem.identity(url) }
        catch let error as TransferEngineError {
            if case .system(let code) = error, code == ENOENT { throw TransferEngineError.invalidTarget }
            throw error
        }
        guard current.device == expected.device, current.inode == expected.inode, current.kind == expected.kind else {
            throw TransferEngineError.invalidTarget
        }
    }

    private func isolateVerifyAndRemoveSource(_ source: URL, target: URL, expected: [String: TransferSnapshot],
                                              targetIdentity: TransferFileIdentity, record: inout TransferJournalRecord,
                                              cancellation: TransferCancellation) throws {
        // Preserve the previous no-side-effect behavior when the source or committed target
        // already changed before cleanup begins.
        guard try TransferFileSystem.manifest(source, cancellation: cancellation) == expected,
              TransferFileSystem.equivalent(expected, try TransferFileSystem.manifest(target, cancellation: cancellation)) else {
            throw TransferEngineError.sourceChanged
        }
        let parent = source.deletingLastPathComponent()
        let parentIdentity = try TransferFileSystem.identity(parent)
        let container = parent.appendingPathComponent(".rightmouse-cleanup-\(record.itemID.uuidString)", isDirectory: true)
        let isolated = container.appendingPathComponent("payload")
        guard mkdir(container.path, 0o700) == 0 else { throw TransferEngineError.system(errno) }
        let containerIdentity = try TransferFileSystem.identity(container)
        record.sourceCleanupURL = isolated
        record.sourceCleanupContainerIdentity = containerIdentity
        record.sourceCleanupState = .isolating
        record.phase = "sourceCleanupIsolating"
        try save(record)
        do {
            try TransferFileSystem.coordinateMutation(source: source, destination: isolated) {
                try checkTargetIdentity(target.deletingLastPathComponent(), expected: targetIdentity)
                let currentParent = try TransferFileSystem.identity(parent)
                guard currentParent.device == parentIdentity.device, currentParent.inode == parentIdentity.inode,
                      currentParent.kind == parentIdentity.kind,
                      try TransferFileSystem.manifest(source, cancellation: cancellation) == expected else {
                    throw TransferEngineError.sourceChanged
                }
                try phaseHookForTesting?("immediatelyBeforeSourceIsolationRename", source, isolated)
                try TransferFileSystem.renameExclusive(source, isolated)
            }
            record.sourceCleanupIdentity = try TransferFileSystem.identity(isolated)
            record.sourceCleanupState = .isolated
            record.phase = "sourceCleanupIsolated"
            try save(record)
            try phaseHookForTesting?("afterSourceIsolation", source, isolated)
            try TransferFileSystem.check(cancellation)
            try checkTargetIdentity(target.deletingLastPathComponent(), expected: targetIdentity)
            let isolatedManifest = try TransferFileSystem.manifest(isolated, cancellation: cancellation)
            guard TransferFileSystem.sameObjectsAfterRename(expected, isolatedManifest),
                  TransferFileSystem.equivalent(expected, try TransferFileSystem.manifest(target, cancellation: cancellation)) else {
                throw TransferEngineError.sourceChanged
            }
            let actualContainer = try TransferFileSystem.identity(container)
            guard actualContainer.device == containerIdentity.device, actualContainer.inode == containerIdentity.inode,
                  actualContainer.kind == containerIdentity.kind else { throw TransferEngineError.sourceChanged }
            // Keep the original per-entry source/target verification. Isolation prevents a
            // later object at the public source path from becoming a cleanup target.
            try TransferFileSystem.removeVerified(isolated, target: target, expected: isolatedManifest, cancellation: cancellation)
            guard rmdir(container.path) == 0 else { throw TransferEngineError.system(errno) }
            record.sourceCleanupState = .completed
            record.sourceCleanupURL = nil
            record.sourceCleanupIdentity = nil
            record.sourceCleanupContainerIdentity = nil
        } catch {
            // If isolation never happened, the empty owned container can be removed and the
            // ordinary source-retained result remains accurate. Once payload exists, preserve it.
            if !TransferFileSystem.exists(isolated),
               let actual = try? TransferFileSystem.identity(container),
               actual.device == containerIdentity.device, actual.inode == containerIdentity.inode,
               actual.kind == containerIdentity.kind, rmdir(container.path) == 0 {
                record.sourceCleanupURL = nil
                record.sourceCleanupIdentity = nil
                record.sourceCleanupContainerIdentity = nil
                record.sourceCleanupState = nil
                record.phase = "sourceCleanupPending"
            } else {
                record.sourceCleanupState = .needsReview
                record.phase = "sourceCleanupNeedsReview"
            }
            try? save(record)
            throw error
        }
    }

    private func decide(policy: TransferConflictPolicy, source: URL, destination: URL,
                        resolve: (@Sendable (URL, URL) async -> TransferConflictDecision)?) async -> TransferConflictDecision {
        switch policy {
        case .skip: return .skip
        case .keepBoth: return .keepBoth
        case .ask: return await resolve?(source, destination) ?? .cancel
        }
    }

    private func nextCandidate(_ name: String, in directory: URL) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty || name.first == "." && !name.dropFirst().contains(".") ? name : (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let suffix = stem == name ? "" : "." + ext
            let candidate = directory.appendingPathComponent("\(stem) \(number)\(suffix)")
            if !TransferFileSystem.exists(candidate) { return candidate }
            number += 1
        }
    }

    private func cleanStaging(_ container: URL?) throws {
        guard let container else { return }
        guard container.lastPathComponent.hasPrefix(".rightmouse-"), let id = UUID(uuidString: String(container.lastPathComponent.dropFirst(12))), container.lastPathComponent == ".rightmouse-\(id.uuidString)" else { throw TransferEngineError.invalidTarget }
        // Verify ownership by the actual created inode, never just a name or a path pattern.
        if TransferFileSystem.exists(container) {
            guard let expected = ownedStaging[container] else { throw TransferEngineError.sourceChanged }
            let actual = try TransferFileSystem.identity(container)
            guard actual.device == expected.device && actual.inode == expected.inode && actual.kind == expected.kind else { throw TransferEngineError.sourceChanged }
            try FileManager.default.removeItem(at: container)
        }
        ownedStaging.removeValue(forKey: container)
    }

    func save(_ record: TransferJournalRecord) throws {
        do { try saveRaw(record) }
        catch { journalFailed = true; throw error }
    }

    private func saveRaw(_ record: TransferJournalRecord) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let file = journalDirectory.appendingPathComponent(record.itemID.uuidString + ".json")
        try PrivateFileIO.ensureDirectory(journalDirectory)
        try PrivateFileIO.write(data, to: file)
        let directoryFD = open(journalDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw TransferEngineError.system(errno) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw TransferEngineError.system(errno) }
    }

    private func finish(_ record: inout TransferJournalRecord, _ result: TransferItemResult) throws -> TransferItemResult {
        record.phase = result.status.rawValue; record.result = result; try save(record); return result
    }

    /// Compatibility API: malformed records are omitted. Use scanRecoveryRecords()
    /// whenever callers need to surface isolated recovery issues.
    public func recoveryRecords() throws -> [TransferJournalRecord] {
        try scanRecoveryRecords().records
    }

    public func scanRecoveryRecords() throws -> TransferRecoveryScan {
        guard FileManager.default.fileExists(atPath: journalDirectory.path) else { return TransferRecoveryScan(records: [], issues: []) }
        try PrivateFileIO.ensureDirectory(journalDirectory)
        var records: [TransferJournalRecord] = [], issues: [TransferRecoveryIssue] = []
        for url in try FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) {
            do { records.append(try validatedRecoveryRecord(at: url)) }
            catch { issues.append(TransferRecoveryIssue(url: url, message: error.localizedDescription)) }
        }
        return TransferRecoveryScan(records: records, issues: issues)
    }

    func validatedRecoveryRecord(at url: URL) throws -> TransferJournalRecord {
        guard let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw TransferEngineError.journalVersion }
        let record = try JSONDecoder().decode(TransferJournalRecord.self, from: PrivateFileIO.read(url, maximumBytes: RequestValidator.maximumBytes))
        guard record.schemaVersion == 1, record.itemID == fileID else { throw TransferEngineError.journalVersion }
        try validateLocal(record.source); try validateLocal(record.destination)
        if let staging = record.stagingURL { try validateLocal(staging) }
        if let cleanup = record.sourceCleanupURL { try validateLocal(cleanup) }
        if let result = record.result {
            guard result.itemID == record.itemID, result.operationID == nil || result.operationID == record.operationID else { throw TransferEngineError.journalVersion }
            try validateLocal(result.source)
            if let destination = result.destination { try validateLocal(destination) }
            if let undo = result.undoToken { try validateLocal(undo.originalURL); try validateLocal(undo.currentURL) }
        }
        return record
    }

    private func validateLocal(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty, url.query == nil, url.fragment == nil, !url.path.contains("\0") else { throw TransferEngineError.invalidSource }
    }

    /// Recovery never replays mutations. A nonterminal record is returned for explicit user review.
    public func recoveryAssessment(_ record: TransferJournalRecord) -> String {
        guard record.schemaVersion == 1 else { return "记录版本未知，请保留现场。" }
        if record.sourceCleanupURL != nil {
            return "来源已进入私有清理隔离区或隔离状态不确定；请核对隔离对象、目标和原路径，不自动删除或重放。"
        }
        let source = try? TransferFileSystem.identity(record.source)
        let target = try? TransferFileSystem.identity(record.destination)
        if let expected = record.destinationIdentity, target == expected {
            return source == nil ? "目标身份匹配，来源已不存在；请核对后确认。" : "来源和目标均存在；请核对两份内容，不自动删除来源。"
        }
        return "证据不足或文件身份已变化；请核对来源、目标与暂存位置。"
    }

    public func undo(_ token: TransferUndoToken, operationID: UUID = UUID()) async throws {
        guard !running, !TransferFileSystem.exists(token.originalURL),
              try TransferFileSystem.identity(token.currentURL) == token.identity else { throw TransferEngineError.unsafeUndo }
        running = true; defer { running = false }
        let expectedManifest = try TransferFileSystem.manifest(token.currentURL, cancellation: TransferCancellation())
        guard try TransferFileSystem.fingerprint(expectedManifest) == token.contentFingerprint else { throw TransferEngineError.unsafeUndo }
        let originalParent = token.originalURL.deletingLastPathComponent()
        let originalParentIdentity = try TransferFileSystem.identity(originalParent)
        var record = TransferJournalRecord(operationID: operationID, itemID: UUID(), source: token.currentURL, destination: token.originalURL, mode: .move, phase: "undoCommitting")
        record.sourceIdentity = token.identity
        try save(record)
        guard try TransferFileSystem.identity(token.currentURL) == token.identity else { throw TransferEngineError.unsafeUndo }
        try TransferFileSystem.coordinateMutation(source: token.currentURL, destination: token.originalURL) {
            guard try TransferFileSystem.identity(token.currentURL) == token.identity,
                  try TransferFileSystem.fingerprint(TransferFileSystem.manifest(token.currentURL, cancellation: TransferCancellation())) == token.contentFingerprint else { throw TransferEngineError.unsafeUndo }
            try phaseHookForTesting?("immediatelyBeforeUndoRename", token.currentURL, token.originalURL)
            try TransferFileSystem.renameExclusive(token.currentURL, token.originalURL)
            try phaseHookForTesting?("immediatelyAfterUndoRename", token.currentURL, token.originalURL)
        }
        let currentParent = try TransferFileSystem.identity(originalParent)
        guard currentParent.device == originalParentIdentity.device, currentParent.inode == originalParentIdentity.inode,
              currentParent.kind == originalParentIdentity.kind,
              TransferFileSystem.sameObjectsAfterRename(expectedManifest, try TransferFileSystem.manifest(token.originalURL, cancellation: TransferCancellation())) else {
            throw TransferEngineError.unsafeUndo
        }
        record.destinationIdentity = try TransferFileSystem.identity(token.originalURL)
        _ = try finish(&record, .init(itemID: record.itemID, operationID: record.operationID, source: token.currentURL, destination: token.originalURL, status: .completed, message: "已撤销移动。"))
    }
}
