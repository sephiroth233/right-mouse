import Foundation
import Darwin
@testable import RightMouseCore

private struct StagingRecoveryCheckFailure: Error, CustomStringConvertible { let description: String }

func runStagingRecoveryChecks() async throws -> Int {
    let fm = FileManager.default
    let requestedRoot = fm.temporaryDirectory.appendingPathComponent("rightmouse-staging-recovery-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: requestedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let physicalRoot = realpath(requestedRoot.path, nil) else { throw POSIXError(.ENOENT) }
    let root = URL(fileURLWithPath: String(cString: physicalRoot), isDirectory: true)
    free(physicalRoot)
    defer { try? fm.removeItem(at: root) }
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try value() else { throw StagingRecoveryCheckFailure(description: title) }
        count += 1; print("PASS staging-recovery: \(title)")
    }
    func setup(_ name: String, legacy: Bool = false, state: StagingCleanupState? = nil) throws -> (FileTransferEngine, URL, URL, URL, URL, TransferJournalRecord) {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let sourceDirectory = base.appendingPathComponent("source", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        let journals = base.appendingPathComponent("journals", isDirectory: true)
        for directory in [sourceDirectory, target, journals] { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let source = sourceDirectory.appendingPathComponent("user.txt")
        try Data("user-source".utf8).write(to: source)
        let itemID = UUID(), operationID = UUID()
        let stage = target.appendingPathComponent(".rightmouse-\(itemID.uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(repeating: 0x42, count: 4096).write(to: stage.appendingPathComponent("payload"))
        var record = TransferJournalRecord(operationID: operationID, itemID: itemID, source: source,
                                           destination: target.appendingPathComponent(source.lastPathComponent), mode: .copy, phase: "staging",
                                           sourceIdentity: try TransferFileSystem.identity(source), destinationIdentity: nil, stagingURL: stage,
                                           stagingIdentity: legacy ? nil : try TransferFileSystem.identity(stage),
                                           stagingParentIdentity: legacy ? nil : try TransferFileSystem.identity(target),
                                           stagingCleanupURL: nil, stagingCleanupState: state, result: nil)
        if state == .requested {
            let cleanup = target.appendingPathComponent(".rightmouse-cleanup-\(itemID.uuidString)", isDirectory: true)
            try fm.moveItem(at: stage, to: cleanup)
            record.stagingCleanupURL = cleanup
        }
        try PrivateFileIO.write(JSONEncoder().encode(record), to: journals.appendingPathComponent(itemID.uuidString + ".json"))
        return (FileTransferEngine(journalDirectory: journals), source, target, stage, journals, record)
    }
    func allowed(_ item: StagingRecoveryItem) throws -> StagingCleanupToken {
        if case let .cleanupAllowed(token) = item.disposition { return token }
        if case let .retainedForReview(reason) = item.disposition { throw StagingRecoveryCheckFailure(description: "candidate was not cleanupAllowed: \(reason)") }
        if case let .legacyEvidenceOnly(reason) = item.disposition { throw StagingRecoveryCheckFailure(description: "candidate was legacy-only: \(reason)") }
        throw StagingRecoveryCheckFailure(description: "candidate was not cleanupAllowed")
    }

    do {
        let (engine, source, target, stage, _, _) = try setup("success")
        let external = root.appendingPathComponent("external-sentinel")
        try Data("external".utf8).write(to: external)
        try fm.createSymbolicLink(at: stage.appendingPathComponent("external-link"), withDestinationURL: external)
        let inspection = await engine.inspectStagingRecovery()
        try check(inspection.items.count == 1 && inspection.issues.isEmpty, "restart inspection finds one owned orphan")
        let matchingInspection = await engine.inspectStagingRecovery(operationID: inspection.items[0].operationID)
        let unrelatedInspection = await engine.inspectStagingRecovery(operationID: UUID())
        try check(matchingInspection.items.count == 1 && unrelatedInspection.items.isEmpty, "operation filter exposes only the authorized task")
        try check(inspection.items[0].occupiedBytes > 0, "inspection reports occupied bytes without following links")
        let result = try await engine.cleanupStaging(try allowed(inspection.items[0]))
        try check(result.removedBytes > 0 && !fm.fileExists(atPath: stage.path), "explicit cleanup removes only the owned stage")
        try check(try Data(contentsOf: source) == Data("user-source".utf8), "cleanup preserves the user source")
        try check(try fm.contentsOfDirectory(atPath: target.path).isEmpty, "cleanup leaves no target payload or private directory")
        try check(try Data(contentsOf: external) == Data("external".utf8), "cleanup unlinks descendant symlink without following it")
        let record = try JSONDecoder().decode(TransferJournalRecord.self, from: Data(contentsOf: root.appendingPathComponent("success/journals/\(result.itemID.uuidString).json")))
        try check(record.stagingCleanupState == .completed && record.stagingURL == nil, "successful cleanup is durably recorded")
    }

    do {
        let (engine, _, _, stage, journals, record) = try setup("journal-change")
        let token = try allowed((await engine.inspectStagingRecovery()).items[0])
        var changed = record; changed.phase = "verified"
        try PrivateFileIO.write(JSONEncoder().encode(changed), to: journals.appendingPathComponent(record.itemID.uuidString + ".json"))
        do { _ = try await engine.cleanupStaging(token); throw StagingRecoveryCheckFailure(description: "changed journal accepted stale token") }
        catch let failure as CommandFailure { try check(failure.code == .recoveryRequired && fm.fileExists(atPath: stage.path), "journal change invalidates cleanup token") }
    }

    do {
        let (engine, _, target, stage, journals, record) = try setup("wrong-parent")
        let rogueParent = root.appendingPathComponent("rogue-parent", isDirectory: true)
        try fm.createDirectory(at: rogueParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let rogueStage = rogueParent.appendingPathComponent(stage.lastPathComponent, isDirectory: true)
        try fm.moveItem(at: stage, to: rogueStage)
        var moved = record
        moved.stagingURL = rogueStage
        moved.stagingIdentity = try TransferFileSystem.identity(rogueStage)
        moved.stagingParentIdentity = try TransferFileSystem.identity(rogueParent)
        try PrivateFileIO.write(JSONEncoder().encode(moved), to: journals.appendingPathComponent(record.itemID.uuidString + ".json"))
        let item = (await engine.inspectStagingRecovery()).items[0]
        if case .retainedForReview = item.disposition {
            try check(fm.fileExists(atPath: rogueStage.path) && fm.fileExists(atPath: target.path), "stage outside destination parent is never cleanupAllowed")
        } else { throw StagingRecoveryCheckFailure(description: "wrong-parent stage unexpectedly allowed") }
    }

    do {
        let (engine, _, _, stage, _, _) = try setup("legacy", legacy: true)
        let item = (await engine.inspectStagingRecovery()).items[0]
        if case .legacyEvidenceOnly = item.disposition { try check(fm.fileExists(atPath: stage.path), "legacy record is display-only and retained") }
        else { throw StagingRecoveryCheckFailure(description: "legacy record unexpectedly allowed cleanup") }
    }

    do {
        let (engine, _, _, stage, _, _) = try setup("replacement")
        let token = try allowed((await engine.inspectStagingRecovery()).items[0])
        try fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { _ = try await engine.cleanupStaging(token); throw StagingRecoveryCheckFailure(description: "replacement stage was deleted") }
        catch let failure as CommandFailure { try check(failure.code == .recoveryRequired && fm.fileExists(atPath: stage.path), "replacement directory identity is refused and retained") }
    }

    do {
        let (engine, _, _, stage, _, record) = try setup("symlink")
        try fm.removeItem(at: stage)
        let outside = root.appendingPathComponent("outside-directory", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: stage, withDestinationURL: outside)
        let item = (await engine.inspectStagingRecovery()).items.first { $0.itemID == record.itemID }!
        if case .retainedForReview = item.disposition { try check(try fm.destinationOfSymbolicLink(atPath: stage.path) == outside.path, "staging symlink is refused without following it") }
        else { throw StagingRecoveryCheckFailure(description: "staging symlink unexpectedly allowed") }
    }

    do {
        let (engine, source, target, stage, _, record) = try setup("committed")
        try Data("committed".utf8).write(to: record.destination)
        let item = (await engine.inspectStagingRecovery()).items[0]
        if case .retainedForReview = item.disposition {
            try check(fm.fileExists(atPath: stage.path) && fm.fileExists(atPath: source.path) && fm.fileExists(atPath: target.path), "existing destination pins staging for review")
        } else { throw StagingRecoveryCheckFailure(description: "committed target unexpectedly allowed cleanup") }
    }

    do {
        let (engine, source, _, stage, _, _) = try setup("source-changed")
        try Data("changed-source".utf8).write(to: source)
        let item = (await engine.inspectStagingRecovery()).items[0]
        if case .retainedForReview = item.disposition { try check(fm.fileExists(atPath: stage.path), "changed source prevents cleanup") }
        else { throw StagingRecoveryCheckFailure(description: "changed source unexpectedly allowed cleanup") }
    }

    do {
        let (engine, source, target, stage, _, _) = try setup("resume", state: .requested)
        let inspection = await engine.inspectStagingRecovery()
        let token = try allowed(inspection.items[0])
        let cleanupURL = target.appendingPathComponent(".rightmouse-cleanup-\(token.itemID.uuidString)")
        try check(!fm.fileExists(atPath: stage.path) && fm.fileExists(atPath: cleanupURL.path), "interrupted rename intent is visible after restart")
        _ = try await engine.cleanupStaging(token)
        try check(!fm.fileExists(atPath: cleanupURL.path) && fm.fileExists(atPath: source.path), "requested cleanup safely resumes after restart")
    }

    return count
}
