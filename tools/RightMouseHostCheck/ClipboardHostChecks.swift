import AppKit
import Foundation
import RightMouseCore

private struct ClipboardCheckFailure: Error, CustomStringConvertible { let description: String }

/// A unique real pasteboard exercises the OS service without touching the user's
/// general clipboard. External writes are simulated through this isolated board.
@MainActor func runClipboardHostChecks() async throws -> Int {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("rightmouse-clipboard-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let marker = NSPasteboard.PasteboardType("cn.rightmouse.pending-move")
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw ClipboardCheckFailure(description: name) }
        count += 1; print("PASS clipboard-host: \(name)")
    }
    func fixture(_ name: String) throws -> (SharedPaths, URL, URL) {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let paths = SharedPaths(root: base.appendingPathComponent("state"), isDevelopmentFallback: true)
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        for url in [source, target] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        return (paths, source, target)
    }
    func file(_ parent: URL, _ name: String, _ text: String = "unchanged") throws -> URL {
        let url = parent.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    func run(_ host: HostController, _ action: CommandAction, _ urls: [URL] = []) async throws -> CommandReceipt {
        let request = CommandRequest(context: ActionContext(entryPoint: .items, container: nil, selection: urls.map { FileReference(url: $0, kindHint: .file) }), action: action)
        guard host.submit(request, interactive: true) else { throw ClipboardCheckFailure(description: "fixture request was not admitted") }
        let terminal: Set<ReceiptStatus> = [.completed, .partial, .failed, .cancelled, .rejected, .needsReview]
        let receiptURL = host.paths.receiptsDirectory.appendingPathComponent(request.requestID.uuidString + ".json")
        for _ in 0..<2000 {
            if let data = try? Data(contentsOf: receiptURL), let receipt = try? WireCodec.decoder().decode(CommandReceipt.self, from: data), terminal.contains(receipt.status) { return receipt }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ClipboardCheckFailure(description: "clipboard request timed out")
    }
    func snapshot(_ paths: SharedPaths) throws -> PendingMoveSnapshot {
        try WireCodec.decoder().decode(PendingMoveSnapshot.self, from: Data(contentsOf: paths.pendingMoveURL))
    }
    func paste(_ token: UUID, _ target: URL, _ policy: ConflictPolicy = .skip) -> CommandAction {
        .pasteMove(pendingToken: token, destination: FileReference(url: target, kindHint: .directory), conflictPolicy: policy)
    }
    do {
        let (paths, source, _) = try fixture("formats")
        let names = ["中文 空格.txt", "quote'\".txt", "line\nbreak.txt", "emoji😀.txt", ".env", "a.tar.gz", "$(touch NEVER).txt", "`touch NEVER`.txt", ";touch NEVER;.txt"]
        let urls = try names.map { try file(source, $0) }
        let host = try HostController(storagePaths: paths, pasteboard: board)
        let expected: [(CopyTextFormat, String)] = [
            (.path, urls.map(\.path).joined(separator: "\n")),
            (.name, names.joined(separator: "\n")),
            (.stem, ["中文 空格", "quote'\"", "line\nbreak", "emoji😀", ".env", "a.tar", "$(touch NEVER)", "`touch NEVER`", ";touch NEVER;"].joined(separator: "\n"))
        ]
        for (format, text) in expected {
            let receipt = try await run(host, .copyText(format: format), urls)
            try check(receipt.status == .completed && board.string(forType: .string) == text, "\(format.rawValue) copies complete special-character multi-selection through the real host")
        }
        let receipt = try await run(host, .copyText(format: .shellPath), urls)
        guard let quoted = board.string(forType: .string) else { throw ClipboardCheckFailure(description: "shell output missing") }
        // Replace only separators between complete quoted arguments. Embedded LF
        // remains inside its argument. sh only sets positional parameters and prints.
        let script = "set -- " + quoted.replacingOccurrences(of: "'\n'", with: "' '") + "\nprintf '%s\\0' \"$@\""
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
        process.currentDirectoryURL = source; process.standardOutput = output
        try process.run()
        let actual = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let expectedBytes = Data((urls.map(\.path).joined(separator: "\0") + "\0").utf8)
        try check(receipt.status == .completed && process.terminationStatus == 0 && actual == expectedBytes, "shellPath survives actual shell argument parsing including quotes and embedded newline")
        try check(!fm.fileExists(atPath: source.appendingPathComponent("NEVER").path), "shell metacharacters perform no injected command")
        try check(try urls.allSatisfy { try Data(contentsOf: $0) == Data("unchanged".utf8) }, "copying every format preserves all source bytes")
    }
    do {
        let (paths, source, target) = try fixture("session")
        let a = try file(source, "a.txt"), b = try file(source, "b.txt")
        let before = try fm.attributesOfItem(atPath: a.path)
        // The snapshot wire format has second precision; use an exact second so
        // the persisted deadline is the same instant as the in-memory deadline.
        var clock = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var host: HostController? = try HostController(storagePaths: paths, pasteboard: board, pendingMoveNow: { clock })
        let cut = try await run(host!, .stageMove, [a, b]); let first = try snapshot(paths)
        let after = try fm.attributesOfItem(atPath: a.path)
        try check(cut.status == .completed && first.count == 2 && board.string(forType: marker) == first.token.uuidString, "cut publishes a session token and exact selection count")
        try check(try Data(contentsOf: a) == Data("unchanged".utf8) && Data(contentsOf: b) == Data("unchanged".utf8) && (before[.posixPermissions] as? NSNumber) == (after[.posixPermissions] as? NSNumber) && (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date), "cut preserves bytes permissions and modification time")
        _ = try await run(host!, .stageMove, [b]); let second = try snapshot(paths)
        try check(second.token != first.token && second.count == 1, "a new cut replaces the previous selection and token")
        let stale = try await run(host!, paste(first.token, target))
        try check(stale.status == .failed && stale.error?.code == .requestExpired && fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path), "old cut token cannot move either selection")
        let moved = try await run(host!, paste(second.token, target))
        try check(moved.status == .completed && !fm.fileExists(atPath: b.path) && fm.fileExists(atPath: a.path), "valid replacement token moves only its own selection")
        try check(!fm.fileExists(atPath: paths.pendingMoveURL.path), "successful complete paste removes the pending selection")
        _ = try await run(host!, .stageMove, [a]); let overwritten = try snapshot(paths)
        board.clearContents(); try check(board.setString("external copy", forType: .string), "isolated external clipboard write succeeds")
        let refused = try await run(host!, paste(overwritten.token, target))
        try check(refused.error?.code == .requestExpired && board.string(forType: .string) == "external copy" && fm.fileExists(atPath: a.path), "external clipboard replacement invalidates cut without reclaiming clipboard")
        _ = try await run(host!, .stageMove, [a]); let replayed = try snapshot(paths)
        board.clearContents(); board.setString(replayed.token.uuidString, forType: marker)
        let replay = try await run(host!, paste(replayed.token, target))
        try check(replay.error?.code == .requestExpired && fm.fileExists(atPath: a.path), "clipboard change invalidates the session even when the old token is replayed")
        _ = try await run(host!, .stageMove, [a]); let expired = try snapshot(paths)
        clock = expired.expiresAt
        let expiry = try await run(host!, paste(expired.token, target))
        try check(expiry.error?.code == .requestExpired && !fm.fileExists(atPath: paths.pendingMoveURL.path), "cut expires exactly at its deadline using an injected clock")
        _ = try await run(host!, .stageMove, [a]); let restart = try snapshot(paths)
        weak var old = host; host = nil
        for _ in 0..<100 { if old == nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard old == nil else { throw ClipboardCheckFailure(description: "session host failed to release") }
        old = nil
        host = try HostController(storagePaths: paths, pasteboard: board)
        let restarted = try await run(host!, paste(restart.token, target))
        try check(restarted.error?.code == .requestExpired && fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: paths.pendingMoveURL.path), "a restarted host never restores a previous cut session")
    }
    do {
        let (paths, source, target) = try fixture("cut-publication-failure")
        let a = try file(source, "a.txt")
        let host = try HostController(storagePaths: paths, pasteboard: board)
        try fm.createDirectory(at: paths.pendingMoveURL, withIntermediateDirectories: false)
        let receipt = try await run(host, .stageMove, [a])
        guard let token = board.string(forType: marker).flatMap(UUID.init(uuidString:)) else { throw ClipboardCheckFailure(description: "failed cut marker missing") }
        try check(receipt.status == .failed && !fm.fileExists(atPath: paths.pendingMoveURL.path), "failed cut snapshot publication invalidates the in-memory session")
        let refused = try await run(host, paste(token, target))
        try check(refused.error?.code == .requestExpired && (try Data(contentsOf: a)) == Data("unchanged".utf8), "a cut reported as failed cannot later move its source")
    }
    do {
        let (paths, source, target) = try fixture("cut-ledger-failure")
        let a = try file(source, "a.txt")
        let commands = paths.operationsDirectory.appendingPathComponent("Commands")
        var clockReads = 0, faultInstalled = false
        let host = try HostController(storagePaths: paths, pasteboard: board, pendingMoveNow: {
            clockReads += 1
            // The second read validates the just-published marker. Deny only the
            // fixture's command directory before its final ledger write; the
            // root-level pending snapshot can still be persisted successfully.
            if clockReads == 2 {
                do { try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: commands.path); faultInstalled = true }
                catch { }
            }
            return Date()
        })
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commands.path) }
        let request = CommandRequest(context: ActionContext(entryPoint: .items, container: nil, selection: [FileReference(url: a, kindHint: .file)]), action: .stageMove)
        guard host.submit(request, interactive: true) else { throw ClipboardCheckFailure(description: "ledger fault request rejected before execution") }
        for _ in 0..<2000 {
            if host.model.tasks.first(where: { $0.id == request.requestID })?.status == "需要核对" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(faultInstalled && host.model.tasks.first(where: { $0.id == request.requestID })?.status == "需要核对", "final cut ledger failure is surfaced as uncertain instead of completed")
        guard let token = board.string(forType: marker).flatMap(UUID.init(uuidString:)) else { throw ClipboardCheckFailure(description: "ledger-failure cut marker missing") }
        try check(!fm.fileExists(atPath: paths.pendingMoveURL.path), "final ledger failure invalidates the already published cut snapshot")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commands.path)
        let refused = try await run(host, paste(token, target))
        try check(refused.error?.code == .requestExpired && (try Data(contentsOf: a)) == Data("unchanged".utf8), "cut with uncertain ledger cannot move files after storage is repaired")
    }
    for fault in ["none", "clipboard", "snapshot"] {
        let (paths, source, target) = try fixture("partial-" + fault)
        let a = try file(source, "a.txt"), b = try file(source, "b.txt")
        _ = try file(target, "b.txt", "occupant")
        let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, _ in
            if fault == "clipboard" { board.clearContents(); board.setString("copied while moving", forType: .string) }
            if fault == "snapshot" { try? fm.removeItem(at: paths.pendingMoveURL); try? fm.createDirectory(at: paths.pendingMoveURL, withIntermediateDirectories: false) }
            return .init(decision: .skip)
        }, pasteboard: board)
        _ = try await run(host, .stageMove, [a, b]); let pending = try snapshot(paths)
        let receipt = try await run(host, paste(pending.token, target, .ask))
        try check(receipt.itemResults.count == 2 && receipt.itemResults.contains { $0.status == "success" } && receipt.itemResults.contains { $0.status == "skipped" }, "\(fault): partial paste retains accurate moved and skipped results")
        try check(!fm.fileExists(atPath: a.path) && (try Data(contentsOf: target.appendingPathComponent("a.txt"))) == Data("unchanged".utf8) && (try Data(contentsOf: b)) == Data("unchanged".utf8), "\(fault): moved target and skipped source remain intact")
        if fault == "none" {
            try check(try snapshot(paths).count == 1 && snapshot(paths).token == pending.token, "partial paste retains only the unsuccessful selection with the same session")
        } else {
            try check(!fm.fileExists(atPath: paths.pendingMoveURL.path), "\(fault): unavailable session is invalidated after preserving file outcomes")
            if fault == "clipboard" { try check(board.string(forType: .string) == "copied while moving", "partial paste never overwrites a later clipboard copy") }
            if fault == "snapshot" { try check(receipt.status != .failed && host.model.errorMessage?.contains("剪切列表更新失败") == true, "snapshot failure reports session failure without replacing the durable file receipt") }
        }
    }
    return count
}
