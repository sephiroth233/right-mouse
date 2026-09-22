import Foundation
import RightMouseCore

private struct FollowupCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Exercises the real host callbacks and persisted records with private fixture files.
@MainActor func runFollowupChecks() async throws -> Int {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-followup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let previousRoot = ProcessInfo.processInfo.environment["RIGHTMOUSE_DATA_DIR"]
    setenv("RIGHTMOUSE_DATA_DIR", root.path, 1)
    defer {
        if let previousRoot { setenv("RIGHTMOUSE_DATA_DIR", previousRoot, 1) }
        else { unsetenv("RIGHTMOUSE_DATA_DIR") }
    }
    let paths = SharedPaths(root: root, isDevelopmentFallback: true)
    try paths.prepare()
    let followups = TaskFollowupStore(directory: paths.operationsDirectory.appendingPathComponent("Followups"))
    let sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
    let targetDirectory = root.appendingPathComponent("targets", isDirectory: true)
    let wrongDirectory = root.appendingPathComponent("different-current-selection", isDirectory: true)
    for directory in [sourceDirectory, targetDirectory, wrongDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw FollowupCheckFailure(description: name) }
        count += 1
        print("PASS followup: \(name)")
    }
    func data(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func sidecar(_ id: UUID) throws -> TaskFollowupRecord {
        guard let value = try followups.read(id) else { throw FollowupCheckFailure(description: "missing follow-up sidecar \(id)") }
        return value
    }
    func receiptBytes(_ id: UUID) throws -> Data {
        try PrivateFileIO.read(paths.receiptsDirectory.appendingPathComponent(id.uuidString + ".json"))
    }
    func newHost() throws -> HostController {
        let host = try HostController(storagePaths: paths)
        guard host.model.save({ $0.revealCreatedFile = false; $0.conflictPolicy = "keepBoth" }) else {
            throw FollowupCheckFailure(description: "could not configure fixture host")
        }
        return host
    }
    var host: HostController? = try newHost()

    // A complete move and undo must survive releasing and rebuilding the host.
    let firstSource = sourceDirectory.appendingPathComponent("undo-complete.txt")
    let firstTarget = targetDirectory.appendingPathComponent(firstSource.lastPathComponent)
    try Data("undo-original".utf8).write(to: firstSource)
    let move = followupRequest(sources: [firstSource], destination: targetDirectory, mode: .move)
    host!.submit(move, interactive: true)
    _ = try await followupWait(host!, id: move.requestID, statuses: ["完成"])
    try check(!exists(firstSource) && data(firstTarget) == Data("undo-original".utf8), "move reaches real target before undo")
    let originalMoveReceipt = try receiptBytes(move.requestID)
    host!.model.onUndoTask?(move.requestID)
    _ = try await followupWait(host!, id: move.requestID, statuses: ["已撤销"])
    let completeSidecar = try sidecar(move.requestID)
    try check(data(firstSource) == Data("undo-original".utf8) && !exists(firstTarget), "undo callback returns file to original path")
    try check(completeSidecar.undoStarted.count == 1 && completeSidecar.undoCompleted == completeSidecar.undoStarted && !completeSidecar.requiresReview, "undo sidecar records durable intent and completion")
    try check(try receiptBytes(move.requestID) == originalMoveReceipt, "undo preserves original move receipt bytes")
    try await releaseFollowupHost(&host)
    host = try newHost()
    let restored = host!.model.tasks.first { $0.id == move.requestID }
    try check(restored?.status == "已撤销" && restored?.canUndo == false, "rebuilt host restores undone state with undo disabled")
    host!.model.onUndoTask?(move.requestID)
    try await Task.sleep(nanoseconds: 30_000_000)
    try check(data(firstSource) == Data("undo-original".utf8) && !exists(firstTarget), "repeated undo callback after restart does not replay completed item")

    // First item can undo; second is blocked by a newly occupied original path.
    let partialA = sourceDirectory.appendingPathComponent("partial-a.txt")
    let partialB = sourceDirectory.appendingPathComponent("partial-b.txt")
    let partialATarget = targetDirectory.appendingPathComponent(partialA.lastPathComponent)
    let partialBTarget = targetDirectory.appendingPathComponent(partialB.lastPathComponent)
    try Data("partial-a".utf8).write(to: partialA)
    try Data("partial-b".utf8).write(to: partialB)
    let partialMove = followupRequest(sources: [partialA, partialB], destination: targetDirectory, mode: .move)
    host!.submit(partialMove, interactive: true)
    _ = try await followupWait(host!, id: partialMove.requestID, statuses: ["完成"])
    try Data("new-occupant".utf8).write(to: partialB)
    host!.model.onUndoTask?(partialMove.requestID)
    let partialTask = try await followupWait(host!, id: partialMove.requestID, statuses: ["需要核对"])
    let partialSidecar = try sidecar(partialMove.requestID)
    try check(data(partialA) == Data("partial-a".utf8) && !exists(partialATarget), "partial undo records first item already restored")
    try check(data(partialB) == Data("new-occupant".utf8) && data(partialBTarget) == Data("partial-b".utf8), "partial undo preserves occupant and second target")
    try check(partialSidecar.undoStarted.count == 2 && partialSidecar.undoCompleted.count == 1 && partialSidecar.requiresReview, "partial undo preserves incomplete second intent")
    try check(!partialTask.canUndo && !partialTask.canRetry && partialTask.canReview, "partial undo requires review and disables automatic replay")
    host!.model.onUndoTask?(partialMove.requestID)
    try await Task.sleep(nanoseconds: 30_000_000)
    let afterRepeatedUndo = try sidecar(partialMove.requestID)
    try check(afterRepeatedUndo.undoStarted == partialSidecar.undoStarted && afterRepeatedUndo.undoCompleted == partialSidecar.undoCompleted, "second undo callback leaves completed and uncertain intents untouched")
    try check(data(partialA) == Data("partial-a".utf8) && data(partialB) == Data("new-occupant".utf8), "blocked second undo does not replay first restored file")
    try await releaseFollowupHost(&host)
    host = try newHost()
    let restoredPartial = host!.model.tasks.first { $0.id == partialMove.requestID }
    try check(restoredPartial?.status == "需要核对" && restoredPartial?.canUndo == false, "restart keeps partial undo in review state")

    // Seed a durable intent as if the host had stopped before recording completion.
    let uncertainSource = sourceDirectory.appendingPathComponent("uncertain-undo.txt")
    let uncertainTarget = targetDirectory.appendingPathComponent(uncertainSource.lastPathComponent)
    try Data("uncertain-bytes".utf8).write(to: uncertainSource)
    let uncertainMove = followupRequest(sources: [uncertainSource], destination: targetDirectory, mode: .move)
    host!.submit(uncertainMove, interactive: true)
    _ = try await followupWait(host!, id: uncertainMove.requestID, statuses: ["完成"])
    try await releaseFollowupHost(&host)
    var uncertainSidecar = try sidecar(uncertainMove.requestID)
    guard let uncertainItem = uncertainSidecar.result?.items.first else { throw FollowupCheckFailure(description: "missing result to seed undo intent") }
    uncertainSidecar.undoStarted.insert(uncertainItem.itemID)
    try followups.save(uncertainSidecar)
    host = try newHost()
    let uncertainTask = host!.model.tasks.first { $0.id == uncertainMove.requestID }
    try check(uncertainTask?.status == "需要核对" && uncertainTask?.canUndo == false, "incomplete persisted undo intent restores as needsReview")
    host!.model.onUndoTask?(uncertainMove.requestID)
    try await Task.sleep(nanoseconds: 30_000_000)
    try check(!exists(uncertainSource) && data(uncertainTarget) == Data("uncertain-bytes".utf8), "restart never replays a seeded uncertain undo")

    // Retry only the failed member and retain the originally resolved destination.
    let successSource = sourceDirectory.appendingPathComponent("retry-success.txt")
    let failedSource = sourceDirectory.appendingPathComponent("retry-unreadable.txt")
    try Data("first-copy".utf8).write(to: successSource)
    try Data("repaired-source".utf8).write(to: failedSource)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: failedSource.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: failedSource.path) }
    let partialCopy = followupRequest(sources: [successSource, failedSource], destination: targetDirectory, mode: .copy)
    host!.submit(partialCopy, interactive: true)
    _ = try await followupWait(host!, id: partialCopy.requestID, statuses: ["部分完成"])
    let originalCopyReceipt = try receiptBytes(partialCopy.requestID)
    let partialResult = try sidecar(partialCopy.requestID)
    try check(partialResult.result?.items.filter { $0.status == .failed }.count == 1 && partialResult.result?.completedCount == 1, "copy fixture produces one success and one failed source")
    // Restore access to the same object without changing its bytes or mtime.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: failedSource.path)
    // If a successful item were replayed with keepBoth it would create a second target.
    try Data("changed-after-first-copy".utf8).write(to: successSource)
    host!.model.destination = wrongDirectory
    let previousTaskIDs = Set(host!.model.tasks.map(\.id))
    // Ledger admission can fail before a child starts. This must not consume the
    // parent's retry opportunity or leave a misleading durable child link.
    let commandsDirectory = paths.operationsDirectory.appendingPathComponent("Commands")
    let previousCommandFiles = Set(try FileManager.default.contentsOfDirectory(atPath: commandsDirectory.path))
    do {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: commandsDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandsDirectory.path) }
        host!.model.errorMessage = nil
        host!.model.onRetryTask?(partialCopy.requestID)
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(try sidecar(partialCopy.requestID).retryRequestID == nil, "ledger write denial preserves an unconsumed retry link")
        try check(try Set(FileManager.default.contentsOfDirectory(atPath: commandsDirectory.path)) == previousCommandFiles, "rejected retry creates no child ledger or temporary file")
        try check(Set(host!.model.tasks.map(\.id)) == previousTaskIDs, "rejected retry creates no child task")
        try check(!exists(targetDirectory.appendingPathComponent(failedSource.lastPathComponent)) && data(failedSource) == Data("repaired-source".utf8), "rejected retry has no file side effect")
        try check(try receiptBytes(partialCopy.requestID) == originalCopyReceipt, "rejected retry preserves original receipt bytes")
        try check(host!.model.tasks.first(where: { $0.id == partialCopy.requestID })?.canRetry == true && host!.model.errorMessage != nil, "retry admission failure reports an error and leaves retry enabled")
    }
    // After restoring the directory, the existing double-click and target checks
    // below prove the same parent can recover and admit exactly one real child.
    host!.model.onRetryTask?(partialCopy.requestID)
    host!.model.onRetryTask?(partialCopy.requestID)
    guard let retryID = try sidecar(partialCopy.requestID).retryRequestID else { throw FollowupCheckFailure(description: "retry did not persist linked child ID") }
    _ = try await followupWait(host!, id: retryID, statuses: ["完成"])
    try check(Set(host!.model.tasks.map(\.id)).subtracting(previousTaskIDs) == [retryID], "double-click retry creates exactly one linked child task")
    let childData = try PrivateFileIO.read(paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(retryID.uuidString + ".json"), maximumBytes: 8 * RequestValidator.maximumBytes)
    let child = try WireCodec.decoder().decode(LedgerEntry.self, from: childData)
    try check(child.request.context.selection.map(\.url) == [failedSource], "retry request contains only explicitly failed source")
    if case let .transfer(mode, destination, _) = child.request.action {
        try check(mode == .copy && destination?.url == targetDirectory, "retry retains original actual target despite new UI destination")
    } else { throw FollowupCheckFailure(description: "retry produced wrong command") }
    try check(data(targetDirectory.appendingPathComponent(failedSource.lastPathComponent)) == Data("repaired-source".utf8), "retry copies repaired failed source successfully")
    let successfulTargets = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("retry-success") }
    try check(successfulTargets.count == 1 && data(successfulTargets[0]) == Data("first-copy".utf8), "retry does not copy successful member again")
    try check(try FileManager.default.contentsOfDirectory(atPath: wrongDirectory.path).isEmpty, "retry makes no change to newly selected UI destination")
    try check(try receiptBytes(partialCopy.requestID) == originalCopyReceipt, "retry preserves original partial receipt bytes")
    try check(host!.model.tasks.first(where: { $0.id == partialCopy.requestID })?.canRetry == false, "original task disables retry after child is linked")
    try await releaseFollowupHost(&host)
    host = try newHost()
    try check(host!.model.tasks.first(where: { $0.id == partialCopy.requestID })?.canRetry == false && (try sidecar(partialCopy.requestID)).retryRequestID == retryID, "restart retains retry link and prevents duplicate child")

    // An attacker or another application may replace the failed source's path.
    // The original readable object remains preserved elsewhere in this fixture.
    let replacedSource = sourceDirectory.appendingPathComponent("identity-source.txt")
    let preservedSource = sourceDirectory.appendingPathComponent("identity-source-preserved.txt")
    let sourceReplacementTarget = root.appendingPathComponent("source-replacement-target", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceReplacementTarget, withIntermediateDirectories: true)
    try Data("original-object".utf8).write(to: replacedSource)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: replacedSource.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacedSource.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preservedSource.path)
    }
    let sourceReplacementRequest = followupRequest(sources: [replacedSource], destination: sourceReplacementTarget, mode: .copy)
    host!.submit(sourceReplacementRequest, interactive: true)
    _ = try await followupWait(host!, id: sourceReplacementRequest.requestID, statuses: ["失败"])
    let sourceReplacementReceipt = try receiptBytes(sourceReplacementRequest.requestID)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacedSource.path)
    try FileManager.default.moveItem(at: replacedSource, to: preservedSource)
    try Data("replacement-one".utf8).write(to: replacedSource)
    let beforeSourceReplacementTasks = Set(host!.model.tasks.map(\.id))
    let beforeSourceReplacementCommands = Set(try FileManager.default.contentsOfDirectory(atPath: commandsDirectory.path))
    host!.model.errorMessage = nil
    host!.model.onRetryTask?(sourceReplacementRequest.requestID)
    try await Task.sleep(nanoseconds: 30_000_000)
    try check(try sidecar(sourceReplacementRequest.requestID).retryRequestID == nil, "replaced source inode is refused without reserving a retry child")
    try check(Set(host!.model.tasks.map(\.id)) == beforeSourceReplacementTasks && (try Set(FileManager.default.contentsOfDirectory(atPath: commandsDirectory.path))) == beforeSourceReplacementCommands, "replaced source creates no child task or ledger")
    try check(data(preservedSource) == Data("original-object".utf8) && data(replacedSource) == Data("replacement-one".utf8), "rejected source replacement preserves both original and replacement objects")
    try check(try FileManager.default.contentsOfDirectory(atPath: sourceReplacementTarget.path).isEmpty, "rejected source replacement writes no destination files")
    try check(try receiptBytes(sourceReplacementRequest.requestID) == sourceReplacementReceipt, "source replacement rejection preserves original receipt")
    try check(host!.model.errorMessage != nil, "source replacement produces a visible refusal")

    // The originally selected target directory can also be replaced at its path.
    let targetReplacementSource = sourceDirectory.appendingPathComponent("identity-target-source.txt")
    let replacedTarget = root.appendingPathComponent("identity-target", isDirectory: true)
    let preservedTarget = root.appendingPathComponent("identity-target-preserved", isDirectory: true)
    try FileManager.default.createDirectory(at: replacedTarget, withIntermediateDirectories: true)
    try Data("original-directory".utf8).write(to: replacedTarget.appendingPathComponent("marker.txt"))
    try Data("unchanged-source".utf8).write(to: targetReplacementSource)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: targetReplacementSource.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetReplacementSource.path) }
    let targetReplacementRequest = followupRequest(sources: [targetReplacementSource], destination: replacedTarget, mode: .copy)
    host!.submit(targetReplacementRequest, interactive: true)
    _ = try await followupWait(host!, id: targetReplacementRequest.requestID, statuses: ["失败"])
    let targetReplacementReceipt = try receiptBytes(targetReplacementRequest.requestID)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetReplacementSource.path)
    try FileManager.default.moveItem(at: replacedTarget, to: preservedTarget)
    try FileManager.default.createDirectory(at: replacedTarget, withIntermediateDirectories: true)
    let beforeTargetReplacementTasks = Set(host!.model.tasks.map(\.id))
    let beforeTargetReplacementCommands = Set(try FileManager.default.contentsOfDirectory(atPath: commandsDirectory.path))
    host!.model.errorMessage = nil
    host!.model.onRetryTask?(targetReplacementRequest.requestID)
    try await Task.sleep(nanoseconds: 30_000_000)
    try check(try sidecar(targetReplacementRequest.requestID).retryRequestID == nil, "replaced destination inode is refused without reserving a retry child")
    try check(Set(host!.model.tasks.map(\.id)) == beforeTargetReplacementTasks && (try Set(FileManager.default.contentsOfDirectory(atPath: commandsDirectory.path))) == beforeTargetReplacementCommands, "replaced destination creates no child task or ledger")
    try check(data(targetReplacementSource) == Data("unchanged-source".utf8) && data(preservedTarget.appendingPathComponent("marker.txt")) == Data("original-directory".utf8), "destination replacement refusal preserves original directory and source")
    try check((try FileManager.default.contentsOfDirectory(atPath: replacedTarget.path)).isEmpty && (try FileManager.default.contentsOfDirectory(atPath: preservedTarget.path)) == ["marker.txt"], "destination replacement refusal changes neither old nor new directory")
    try check(try receiptBytes(targetReplacementRequest.requestID) == targetReplacementReceipt, "destination replacement rejection preserves original receipt")
    try check(host!.model.errorMessage != nil, "destination replacement produces a visible refusal")
    try await releaseFollowupHost(&host)
    return count
}

private func followupRequest(sources: [URL], destination: URL, mode: CommandTransferMode) -> CommandRequest {
    CommandRequest(context: ActionContext(entryPoint: .items, container: nil, selection: sources.map { FileReference(url: $0, kindHint: .file) }),
                   action: .transfer(mode: mode, destination: FileReference(url: destination, kindHint: .directory), conflictPolicy: .keepBoth))
}

@MainActor private func followupWait(_ host: HostController, id: UUID, statuses: Set<String>) async throws -> TaskPresentation {
    let otherTerminal: Set<String> = ["完成", "部分完成", "失败", "已取消", "需要核对", "已撤销", "部分撤销"]
    for _ in 0..<2000 {
        if let task = host.model.tasks.first(where: { $0.id == id }) {
            if statuses.contains(task.status) { return task }
            if otherTerminal.contains(task.status) { throw FollowupCheckFailure(description: "task \(id) unexpectedly ended \(task.status): \(task.detail)") }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw FollowupCheckFailure(description: "task \(id) timed out; error: \(host.model.errorMessage ?? "none")")
}

@MainActor private func releaseFollowupHost(_ host: inout HostController?) async throws {
    weak var previous = host
    defer { previous = nil }
    host = nil
    for _ in 0..<100 {
        if previous == nil { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw FollowupCheckFailure(description: "host remained alive after fixture task completion; cannot reopen ledger")
}
