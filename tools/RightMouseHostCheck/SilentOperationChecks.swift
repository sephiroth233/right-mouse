import AppKit
import Foundation
import RightMouseCore

private struct SilentOperationFailure: Error { let message: String }

/// Exercise production defaults, real files and an isolated pasteboard. Only
/// launching an external app is substituted; no personal files are touched.
@MainActor func runSilentOperationChecks() async throws -> Int {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/rightmouse-silent-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let paths = SharedPaths(root: root.appendingPathComponent("state"), isDevelopmentFallback: true)
    let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
    for url in [source, target] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
    let file = source.appendingPathComponent("sample.txt")
    try Data("payload".utf8).write(to: file)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    var opened = 0, windows = 0, conflicts = 0, count = 0
    let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, _ in conflicts += 1; return .init(decision: .keepBoth) }, openApplication: { _, _ in opened += 1 }, pasteboard: board)
    host.model.save { $0.revealCreatedFile = false }
    host.showTasks = { windows += 1 }
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SilentOperationFailure(message: message) }
        count += 1; print("PASS silent: \(message)")
    }
    var commands: [CommandRequest] = []
    func run(_ action: CommandAction, files: [URL] = []) async throws -> CommandReceipt {
        var request = CommandRequest(context: .init(entryPoint: files.isEmpty ? .container : .items, container: .init(url: source, kindHint: .directory), selection: files.map { .init(url: $0, kindHint: .file) }), action: action)
        // Exercise expiry without slowing the entire regression suite by 2 minutes.
        request.expiresAt = Date().addingTimeInterval(2)
        commands.append(request)
        try check(host.submit(request, interactive: true), "request admitted: \(action.type)")
        let receiptURL = paths.receiptsDirectory.appendingPathComponent(request.requestID.uuidString + ".json")
        for _ in 0..<500 {
            if let data = try? Data(contentsOf: receiptURL), let receipt = try? WireCodec.decoder().decode(CommandReceipt.self, from: data), [.completed, .failed, .cancelled, .partial, .needsReview].contains(receipt.status) { return receipt }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SilentOperationFailure(message: "operation timed out")
    }
    let create = try await run(.createFile(templateID: "txt", destination: .init(url: source, kindHint: .directory), name: "created.txt"))
    try check(create.status == .completed, "create succeeds silently")
    let copy = try await run(.copyText(format: .path), files: [file])
    try check(copy.status == .completed && board.string(forType: .string) == file.path, "copy path succeeds silently")
    let open = try await run(.openWith(integrationID: "terminal", mode: .directory))
    try check(open.status == .completed && opened == 1, "open succeeds silently")
    let cut = try await run(.stageMove, files: [file])
    let pending = try WireCodec.decoder().decode(PendingMoveSnapshot.self, from: Data(contentsOf: paths.pendingMoveURL))
    try check(cut.status == .completed, "cut succeeds silently")
    let paste = try await run(.pasteMove(pendingToken: pending.token, destination: .init(url: target, kindHint: .directory), conflictPolicy: .ask))
    try check(paste.status == .completed && !fm.fileExists(atPath: file.path), "paste moves the source")
    let copied = try await run(.transfer(mode: .copy, destination: .init(url: source, kindHint: .directory), conflictPolicy: .ask), files: [target.appendingPathComponent("sample.txt")])
    let moved = try await run(.transfer(mode: .move, destination: .init(url: target, kindHint: .directory), conflictPolicy: .ask), files: [file])
    try check(copied.status == .completed && moved.status == .completed && conflicts == 1, "copy and move remain silent while a real collision still asks")
    try check(windows == 0 && host.model.recoveryTasks.isEmpty && host.model.errorMessage == nil, "all successful features produce no task popup or recovery history")
    host.cleanupFinishedOperations()
    try check(fm.fileExists(atPath: paths.receiptsDirectory.appendingPathComponent(create.requestID.uuidString + ".json").path), "unexpired receipt retained to prevent duplicate execution")
    try check(host.submit(commands[0], interactive: true), "duplicate transport delivery acknowledged")
    try check(try fm.contentsOfDirectory(atPath: source.path).count == 1, "duplicate create does not create another file")
    let oldLog = DiagnosticLogStore(directory: paths.privateRoot.appendingPathComponent("Diagnostics"))
    oldLog.append(component: .host, event: .requestFinished, requestID: UUID(), action: .createFile, status: .completed)
    let exported = try host.model.onExportDiagnostics!()
    let text = String(decoding: exported.data, as: UTF8.self)
    try check(!text.contains("requestID") && !text.contains("requestFinished"), "legacy per-operation diagnostic events removed on export")
    try await Task.sleep(nanoseconds: 2_200_000_000)
    host.cleanupFinishedOperations()
    for directory in [paths.receiptsDirectory, paths.operationsDirectory.appendingPathComponent("Commands"), paths.operationsDirectory.appendingPathComponent("Transfers"), paths.operationsDirectory.appendingPathComponent("Followups")] {
        try check(try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.isEmpty, "expired terminal records removed from \(directory.lastPathComponent)")
    }
    try check(host.model.tasks.isEmpty, "temporary in-memory results discarded with transport state")
    try check(try Data(contentsOf: target.appendingPathComponent("sample.txt")) == Data("payload".utf8), "cleanup never changes moved file bytes")
    try check(!host.submit(commands[0], interactive: true), "expired request cannot replay after record cleanup")
    try check(windows == 0, "rejected stale delivery does not show task window")
    // Existing completed history is migrated on launch; incomplete work remains
    // recovery evidence and must never be replayed merely by reopening the app.
    let oldPaths = SharedPaths(root: root.appendingPathComponent("legacy"), isDevelopmentFallback: true)
    try oldPaths.prepare()
    let oldRequest = CommandRequest(context: .init(entryPoint: .items, container: nil, selection: [.init(url: file)]), action: .copyText(format: .path), now: Date().addingTimeInterval(-180))
    let interrupted = CommandRequest(context: oldRequest.context, action: .createFile(templateID: "txt", destination: .init(url: source, kindHint: .directory), name: "interrupted.txt"), now: oldRequest.createdAt)
    do {
        let ledger = try CommandLedger(directory: oldPaths.operationsDirectory.appendingPathComponent("Commands"))
        var entry = try ledger.accept(oldRequest, now: oldRequest.createdAt).entry
        entry.receipt = CommandReceipt(requestID: oldRequest.requestID, status: .completed)
        try ledger.save(entry)
        try PrivateFileIO.write(WireCodec.encoder().encode(entry.receipt), to: oldPaths.receiptsDirectory.appendingPathComponent(oldRequest.requestID.uuidString + ".json"))
        _ = try ledger.accept(interrupted, now: interrupted.createdAt)
    }
    let restarted = try HostController(storagePaths: oldPaths, pasteboard: board)
    try check(!fm.fileExists(atPath: oldPaths.operationsDirectory.appendingPathComponent("Commands/" + oldRequest.requestID.uuidString + ".json").path), "startup removes completed legacy history without a 30-day wait")
    try check(restarted.model.recoveryTasks.map(\.id) == [interrupted.requestID], "startup preserves only incomplete work for manual file recovery")
    return count
}
