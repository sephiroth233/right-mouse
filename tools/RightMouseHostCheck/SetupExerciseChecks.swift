import Foundation
import RightMouseCore

private struct SetupExerciseCheckFailure: Error, CustomStringConvertible { let description: String }

@MainActor func runSetupExerciseChecks() async throws -> Int {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("rightmouse-setup-exercise-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw SetupExerciseCheckFailure(description: title) }
        count += 1
    }
    let target = root.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let model = AppModel(configurationStore: ConfigurationStore(directory: root.appendingPathComponent("model-config")), templateStore: TemplateStore(directory: root.appendingPathComponent("model-templates")))
    var dispatched: [UUID] = []
    model.onRunSetupExercise = { _, id in dispatched.append(id); return true }
    model.acceptSetupExerciseSelection(nil)
    try check(model.setupExercisePhase == .idle && dispatched.isEmpty, "cancelled directory selection started exercise")
    model.acceptSetupExerciseSelection(target)
    try check(model.setupExerciseTarget == target && model.setupExercisePhase == .ready && dispatched.isEmpty, "selecting a directory silently created a task")
    model.isReadOnly = true
    try check(!model.beginSetupExercise(at: target) && dispatched.isEmpty, "read-only configuration allowed exercise creation")
    model.isReadOnly = false
    try check(model.beginSetupExercise(at: target) && model.setupExercisePhase == .waiting && dispatched.count == 1, "accepted exercise did not enter waiting state")
    let firstID = model.setupExerciseRequestID!
    try check(!model.beginSetupExercise(at: target) && dispatched.count == 1, "double-click dispatched a second exercise")
    model.updateTask(TaskPresentation(id: firstID, title: "新建文件", status: "完成"))
    try check(model.setupExercisePhase == .waiting, "task presentation was mistaken for a successful receipt")
    let item = ItemReceipt(status: "success", destinationURL: target.appendingPathComponent("RightMouse 演练.txt"))
    model.receiveSetupReceipt(CommandReceipt(requestID: UUID(), revision: 10, status: .completed, itemResults: [item]))
    try check(model.setupExercisePhase == .waiting && model.setupExerciseResult == nil, "another request receipt completed exercise")
    model.receiveSetupReceipt(CommandReceipt(requestID: firstID, revision: 2, status: .running, itemResults: [item]))
    try check(model.setupExercisePhase == .waiting, "nonterminal receipt with success item completed exercise")
    model.receiveSetupReceipt(CommandReceipt(requestID: firstID, revision: 1, status: .completed, itemResults: [item]))
    try check(model.setupExercisePhase == .waiting, "stale receipt revision completed exercise")
    model.receiveSetupReceipt(CommandReceipt(requestID: firstID, revision: 3, status: .failed, itemResults: [item], error: .init(.accessDenied, "fixture denied")))
    try check(model.setupExercisePhase == .failed && model.setupExerciseResult == nil, "failed receipt with a success item reported exercise success")
    try check(model.beginSetupExercise(at: target) && model.setupExerciseRequestID != firstID && dispatched.count == 2, "retry reused failed exercise ID")
    let secondID = model.setupExerciseRequestID!
    model.receiveSetupReceipt(CommandReceipt(requestID: firstID, revision: 4, status: .completed, itemResults: [item]))
    try check(model.setupExercisePhase == .waiting, "late prior request receipt completed a new exercise")
    model.receiveSetupReceipt(CommandReceipt(requestID: secondID, revision: 1, status: .completed, itemResults: [.init(status: "skipped", destinationURL: item.destinationURL)]))
    try check(model.setupExercisePhase == .needsReview && model.setupExerciseResult == nil, "completed but skipped result counted as file creation")
    model.acceptSetupExerciseSelection(target)
    _ = model.beginSetupExercise(at: target)
    let thirdID = model.setupExerciseRequestID!
    var future = CommandReceipt(requestID: thirdID, status: .completed, itemResults: [item]); future.schemaVersion = 2
    model.receiveSetupReceipt(future)
    try check(model.setupExercisePhase == .waiting, "future receipt schema completed exercise")
    model.receiveSetupReceipt(CommandReceipt(requestID: thirdID, status: .completed))
    try check(model.setupExercisePhase == .needsReview, "completed receipt without file result completed exercise")
    model.acceptSetupExerciseSelection(target)
    _ = model.beginSetupExercise(at: target)
    let fourthID = model.setupExerciseRequestID!
    model.receiveSetupReceipt(CommandReceipt(requestID: fourthID, status: .completed, itemResults: [.init(status: "success", destinationURL: URL(string: "https://example.invalid/file.txt"))]))
    try check(model.setupExercisePhase == .needsReview, "remote result URL completed local TXT exercise")
    model.acceptSetupExerciseSelection(target)
    _ = model.beginSetupExercise(at: target)
    let fifthID = model.setupExerciseRequestID!
    model.receiveSetupReceipt(CommandReceipt(requestID: fifthID, status: .completed, itemResults: [item]))
    try check(model.setupExercisePhase == .succeeded && model.setupExerciseResult == item.destinationURL, "matching completed success receipt did not publish actual result")
    model.receiveSetupReceipt(CommandReceipt(requestID: fifthID, revision: 2, status: .failed))
    try check(model.setupExercisePhase == .succeeded, "late receipt replaced terminal exercise result")
    model.acceptSetupExerciseSelection(target)
    model.onRunSetupExercise = { _, id in
        model.receiveSetupReceipt(CommandReceipt(requestID: id, status: .completed, itemResults: [item]))
        return true
    }
    _ = model.beginSetupExercise(at: target)
    try check(model.setupExercisePhase == .succeeded, "synchronous host receipt raced request ID installation")
    model.acceptSetupExerciseSelection(target)
    model.onRunSetupExercise = { _, _ in false }
    try check(!model.beginSetupExercise(at: target) && model.setupExercisePhase == .failed, "rejected dispatch stayed waiting or reported success")
    model.onRunSetupExercise = nil
    try check(!model.beginSetupExercise(at: target) && model.setupExercisePhase == .failed, "missing host callback reported exercise success")

    // Integration uses the actual host callback/publisher, creator, ledger, and
    // no-clobber naming. No clipboard, real application launch, or user directory.
    let hostRoot = root.appendingPathComponent("host", isDirectory: true)
    let paths = SharedPaths(root: hostRoot, isDevelopmentFallback: true)
    let host = try HostController(storagePaths: paths)
    host.model.save { $0.revealCreatedFile = false }
    try check(host.model.onRunSetupExercise != nil, "real host did not install exercise dispatch")
    let existing = target.appendingPathComponent("RightMouse 演练.txt")
    let original = Data("preserve preexisting content".utf8)
    try original.write(to: existing)
    host.model.acceptSetupExerciseSelection(target)
    try check(try FileManager.default.contentsOfDirectory(atPath: target.path).count == 1 && host.model.setupExerciseRequestID == nil, "real host created a file during directory selection")
    try check(host.model.beginSetupExercise(at: target), "real host rejected a valid exercise")
    let realID = host.model.setupExerciseRequestID!
    try check(!host.model.beginSetupExercise(at: target), "real host accepted exercise double-click")
    try await waitForSetupExercise(host.model)
    try check(host.model.setupExercisePhase == .succeeded && host.model.setupExerciseResult?.lastPathComponent == "RightMouse 演练 2.txt", "real exercise did not complete using safe no-clobber naming")
    try check(try Data(contentsOf: existing) == original && Data(contentsOf: host.model.setupExerciseResult!).isEmpty, "real exercise overwrote an existing file or emitted non-TXT bytes")
    let ledgerURL = paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(realID.uuidString + ".json")
    let entry = try WireCodec.decoder().decode(LedgerEntry.self, from: PrivateFileIO.read(ledgerURL))
    try check(entry.receipt.status == .completed && entry.receipt.itemResults.count == 1 && entry.receipt.itemResults[0].status == "success" && entry.receipt.itemResults[0].destinationURL == host.model.setupExerciseResult, "exercise success lacks corresponding real completed ledger receipt")
    host.model.save { $0.templates.removeAll { $0.id == "txt" } }
    host.model.acceptSetupExerciseSelection(target)
    _ = host.model.beginSetupExercise(at: target)
    let failedID = host.model.setupExerciseRequestID!
    try await waitForSetupExercise(host.model)
    try check(host.model.setupExercisePhase == .failed && host.model.setupExerciseResult == nil, "real host missing-template failure falsely completed exercise")
    try check(try FileManager.default.contentsOfDirectory(atPath: target.path).count == 2, "failed exercise created an unreported file")
    host.model.save { $0.templates.append(FileTemplate.builtIns.first { $0.id == "txt" }!) }
    try check(host.model.beginSetupExercise(at: target) && host.model.setupExerciseRequestID != failedID, "real exercise retry did not get a fresh request ID")
    try await waitForSetupExercise(host.model)
    try check(host.model.setupExercisePhase == .succeeded && host.model.setupExerciseResult?.lastPathComponent == "RightMouse 演练 3.txt", "real exercise retry did not complete with a distinct result")
    return count
}

@MainActor private func waitForSetupExercise(_ model: AppModel) async throws {
    for _ in 0..<1500 {
        if model.setupExercisePhase != .waiting { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw SetupExerciseCheckFailure(description: "exercise timed out: \(model.setupExerciseMessage)")
}
