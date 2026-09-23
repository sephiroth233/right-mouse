import Foundation
import RightMouseCore

private struct ConflictCheckFailure: Error, CustomStringConvertible { let description: String }

/// Uses the real host and engine with temporary files and injected prompt responses.
/// No NSApplication, dialog or actual fifteen-minute delay is needed.
@MainActor func runConflictChecks() async throws -> Int {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-conflicts-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw ConflictCheckFailure(description: name) }
        count += 1; print("PASS conflict: \(name)")
    }
    func data(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func fixture(_ label: String) throws -> (SharedPaths, URL, URL) {
        let base = root.appendingPathComponent(label, isDirectory: true)
        let paths = SharedPaths(root: base.appendingPathComponent("state"), isDevelopmentFallback: true)
        try paths.prepare()
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        for directory in [source, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return (paths, source, target)
    }
    func seed(_ directory: URL, _ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name); try Data(contents.utf8).write(to: url); return url
    }
    func entry(_ paths: SharedPaths, _ id: UUID) throws -> LedgerEntry {
        try WireCodec.decoder().decode(LedgerEntry.self, from: PrivateFileIO.read(paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(id.uuidString + ".json")))
    }

    // Removed preferences must not silently skip or rename a new UI operation.
    for (action, legacyPolicy) in [("copyTo", "skip"), ("moveTo", "keepBoth"), ("pasteMove", "skip")] {
        let (paths, source, target) = try fixture("legacy-" + action)
        let file = try seed(source, "collision.txt", "incoming")
        let existing = try seed(target, "collision.txt", "existing")
        var prompts = 0
        let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, _ in
            prompts += 1
            return .init(decision: .skip)
        })
        try check(host.model.save { $0.conflictPolicy = legacyPolicy }, "\(action): seed legacy conflict preference")
        if action == "pasteMove" {
            let staged = CommandRequest(context: ActionContext(entryPoint: .items,
                container: FileReference(url: source, kindHint: .directory), selection: [FileReference(url: file)]), action: .stageMove)
            host.submit(staged, interactive: true)
            for _ in 0..<1_000 {
                if try entry(paths, staged.requestID).receipt.status == .completed { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(try entry(paths, staged.requestID).receipt.status == .completed, "pasteMove: cut is durably ready")
        }
        let previous = Set(host.model.tasks.map(\.id))
        host.perform(action, files: action == "pasteMove" ? [] : [file], destination: target)
        guard let task = host.model.tasks.first(where: { !previous.contains($0.id) }) else {
            throw ConflictCheckFailure(description: "missing legacy preference task")
        }
        _ = try await conflictWait(host, task.id)
        try check(prompts == 1, "\(action): asks despite legacy \(legacyPolicy) preference")
        try check(data(file) == Data("incoming".utf8) && data(existing) == Data("existing".utf8)
                  && (try FileManager.default.contentsOfDirectory(atPath: target.path)).count == 1,
                  "\(action): explicit skip preserves source and target without creating a renamed copy")
    }

    // Both choices can apply to a batch; ordinary single-item choices still prompt twice.
    for (label, decision, batch) in [("single", TransferConflictDecision.keepBoth, false), ("batch-keep", .keepBoth, true), ("batch-skip", .skip, true)] {
        let (paths, source, target) = try fixture(label)
        let a = try seed(source, "a.txt", "source-a"), b = try seed(source, "b.txt", "source-b")
        _ = try seed(target, "a.txt", "occupant-a"); _ = try seed(target, "b.txt", "occupant-b")
        var prompts = 0
        let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, _ in
            prompts += 1; return .init(decision: decision, applyToRemaining: batch)
        })
        let request = conflictRequest([a, b], target)
        host.submit(request, interactive: true); _ = try await conflictWait(host, request.requestID)
        try check(prompts == (batch ? 1 : 2), "\(label): prompt count follows explicit batch scope")
        try check(data(target.appendingPathComponent("a.txt")) == Data("occupant-a".utf8) && data(target.appendingPathComponent("b.txt")) == Data("occupant-b".utf8), "\(label): existing targets retain their bytes")
        let result = try entry(paths, request.requestID).receipt.itemResults
        try check(result.count == 2 && result.allSatisfy { $0.status == (decision == .skip ? "skipped" : "success") }, "\(label): both items record the selected outcome")
        let again = conflictRequest([a], target)
        host.submit(again, interactive: true); _ = try await conflictWait(host, again.requestID)
        try check(prompts == (batch ? 2 : 3), "\(label): a later task asks again instead of inheriting the batch decision")
    }

    // Observe the actual persisted/UI waiting state from inside the injected prompt.
    // Cancel and timeout leave an already completed first copy in place.
    for (label, reason) in [("cancel", ConflictResolution.Reason.user), ("token-cancel", .cancelled), ("timeout", .timedOut), ("unavailable", .unavailable)] {
        let (paths, source, target) = try fixture(label)
        let first = try seed(source, "first.txt", "completed-first")
        let collision = try seed(source, "collision.txt", "incoming")
        let last = try seed(source, "last.txt", "unstarted-last")
        _ = try seed(target, "collision.txt", "occupant")
        let request = conflictRequest([first, collision, last], target)
        var waitingDurable = false, waitingUI = false, firstPresentWhileWaiting = false, prompts = 0
        weak var observedHost: HostController?
        let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, token in
            prompts += 1
            // Yield once to catch stale progress callbacks incorrectly overwriting waiting UI.
            try? await Task.sleep(nanoseconds: 30_000_000)
            waitingDurable = (try? entry(paths, request.requestID).receipt.status) == .waitingForUser
            let waitingTask = observedHost?.model.tasks.first(where: { $0.id == request.requestID })
            waitingUI = waitingTask?.status == "等待选择" && waitingTask?.completed == 1 && waitingTask?.total == 3
            firstPresentWhileWaiting = data(target.appendingPathComponent("first.txt")) == Data("completed-first".utf8)
            if reason == .cancelled { token.cancel() }
            return .init(decision: .cancel, applyToRemaining: true, reason: reason)
        })
        observedHost = host
        host.submit(request, interactive: true); let task = try await conflictWait(host, request.requestID)
        try check(prompts == 1 && waitingDurable && waitingUI, "\(label): prompt sees durable waiting state and matching UI")
        try check(firstPresentWhileWaiting && data(target.appendingPathComponent("first.txt")) == Data("completed-first".utf8), "\(label): cancellation preserves the already completed first item")
        try check(!exists(target.appendingPathComponent("last.txt")) && data(target.appendingPathComponent("collision.txt")) == Data("occupant".utf8), "\(label): remaining items do not execute or overwrite occupants")
        try check(try entry(paths, request.requestID).receipt.status != .waitingForUser, "\(label): terminal receipt leaves waiting state")
        if reason == .timedOut { try check(task.detail.contains("15 分钟") && task.detail.contains("已取消"), "timeout: terminal task explains why remaining work stopped") }
    }

    // Replace a source parent or target directory while the host awaits the prompt.
    for replaceTarget in [false, true] {
        let label = replaceTarget ? "target-replaced" : "source-parent-replaced"
        let (paths, source, target) = try fixture(label)
        let incoming = try seed(source, "same.txt", "original-source")
        _ = try seed(target, "same.txt", "original-target")
        let movedAside = (replaceTarget ? target : source).appendingPathExtension("original")
        var mutationError: Error?
        let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, _ in
            do {
                let replaced = replaceTarget ? target : source
                try FileManager.default.moveItem(at: replaced, to: movedAside)
                try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
                _ = try seed(replaced, "same.txt", "replacement")
            } catch { mutationError = error }
            return .init(decision: .keepBoth)
        })
        let request = conflictRequest([incoming], target)
        host.submit(request, interactive: true); _ = try await conflictWait(host, request.requestID)
        if let mutationError { throw mutationError }
        let results = try entry(paths, request.requestID).receipt.itemResults
        try check(results.count == 1 && results[0].status == "failed", "\(label): identity change is refused after keep-both response")
        try check(try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).count == 1, "\(label): refusal does not create a numbered copy")
        try check(data(movedAside.appendingPathComponent("same.txt")) == Data((replaceTarget ? "original-target" : "original-source").utf8), "\(label): displaced original remains untouched")
        try check(data((replaceTarget ? target : source).appendingPathComponent("same.txt")) == Data("replacement".utf8), "\(label): replacement remains untouched")
    }

    // A process restart has no live dialog: persisted waiting becomes needsReview.
    do {
        let (paths, source, target) = try fixture("recovery")
        let incoming = try seed(source, "recover.txt", "source")
        let request = conflictRequest([incoming], target)
        do {
            let ledger = try CommandLedger(directory: paths.operationsDirectory.appendingPathComponent("Commands"))
            _ = try ledger.accept(request)
            guard var saved = try ledger.entry(request.requestID) else { throw ConflictCheckFailure(description: "missing seeded entry") }
            saved.receipt.status = .waitingForUser; try ledger.save(saved)
        }
        var prompts = 0
        let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, _ in prompts += 1; return .init(decision: .keepBoth) })
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(host.model.tasks.first(where: { $0.id == request.requestID })?.status == "需要核对" && (try entry(paths, request.requestID).receipt.status) == .needsReview, "recovery: waiting task restores as durable needsReview")
        try check(prompts == 0 && !exists(target.appendingPathComponent("recover.txt")) && data(incoming) == Data("source".utf8), "recovery: restart does not replay waiting operation or present a prompt")
    }

    // Make only the Commands directory unwritable after running is committed.
    // The engine can finish item 1, but the next waiting transition must fail closed.
    do {
        let (paths, source, target) = try fixture("waiting-log-denied")
        let first = try seed(source, "first.txt", "completed")
        let collision = try seed(source, "collision.txt", "incoming")
        let last = try seed(source, "last.txt", "not-started")
        _ = try seed(target, "collision.txt", "occupant")
        let commands = paths.operationsDirectory.appendingPathComponent("Commands")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commands.path) }
        var prompts = 0, setupError: Error?, blocked = false
        let host = try HostController(storagePaths: paths, conflictPrompt: { _, _, _ in prompts += 1; return .init(decision: .keepBoth) })
        host.showTasks = {
            guard !blocked else { return }; blocked = true
            do { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: commands.path) } catch { setupError = error }
        }
        let request = conflictRequest([first, collision, last], target)
        host.submit(request, interactive: true); let task = try await conflictWait(host, request.requestID)
        if let setupError { throw setupError }
        try check(blocked && prompts == 0, "waiting-log denial: failure prevents calling conflict prompt")
        try check(task.status == "需要核对" && task.canReview && !task.canRetry && !task.canUndo, "waiting-log denial: task requires review without replay actions")
        try check(data(target.appendingPathComponent("first.txt")) == Data("completed".utf8), "waiting-log denial: completed first item is preserved")
        try check(!exists(target.appendingPathComponent("last.txt")) && data(target.appendingPathComponent("collision.txt")) == Data("occupant".utf8), "waiting-log denial: no later side effect occurs")
    }
    return count
}

private func conflictRequest(_ sources: [URL], _ destination: URL) -> CommandRequest {
    CommandRequest(context: ActionContext(entryPoint: .items, container: sources.first.map { FileReference(url: $0.deletingLastPathComponent(), kindHint: .directory) }, selection: sources.map { FileReference(url: $0, kindHint: .file) }), action: .transfer(mode: .copy, destination: FileReference(url: destination, kindHint: .directory), conflictPolicy: .ask))
}

@MainActor private func conflictWait(_ host: HostController, _ id: UUID) async throws -> TaskPresentation {
    let terminal = Set(["完成", "部分完成", "失败", "已取消", "需要核对"])
    for _ in 0..<1_000 {
        if let task = host.model.tasks.first(where: { $0.id == id }), terminal.contains(task.status) { return task }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw ConflictCheckFailure(description: "conflict task \(id) timed out")
}
