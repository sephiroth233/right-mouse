import Foundation
import RightMouseCore

private struct SourceRecoveryHostFailure: Error, CustomStringConvertible { let description: String }

@MainActor func runSourceRecoveryHostChecks() async throws -> Int {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-source-review-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = SharedPaths(root: root.appendingPathComponent("shared"), privateRoot: root.appendingPathComponent("private"))
    try paths.prepare()
    let sourceParent = root.appendingPathComponent("sources"), target = root.appendingPathComponent("target")
    for directory in [sourceParent, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    let source = sourceParent.appendingPathComponent("original.txt")
    let destination = target.appendingPathComponent("original.txt")
    let itemID = UUID()
    let recovery = sourceParent.appendingPathComponent(".rightmouse-cleanup-" + itemID.uuidString).appendingPathComponent("payload")
    try FileManager.default.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("isolated source evidence".utf8).write(to: recovery)
    try Data("new occupant at original path".utf8).write(to: source)
    try Data("committed target".utf8).write(to: destination)
    let request = CommandRequest(context: ActionContext(entryPoint: .items, container: FileReference(url: sourceParent), selection: [FileReference(url: source)]), action: .transfer(mode: .move, destination: FileReference(url: target), conflictPolicy: .skip))
    do { let ledger = try CommandLedger(directory: paths.operationsDirectory.appendingPathComponent("Commands")); _ = try ledger.accept(request) }
    let journalURL = paths.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(itemID.uuidString + ".json")
    let json: [String: Any] = ["schemaVersion": 1, "operationID": request.requestID.uuidString, "itemID": itemID.uuidString,
                               "source": source.absoluteString, "destination": destination.absoluteString, "mode": "move",
                               "phase": "sourceCleanupPending", "sourceCleanupURL": recovery.absoluteString]
    let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    try PrivateFileIO.write(bytes, to: journalURL)
    let host = try HostController(storagePaths: paths)
    host.model.onReviewTask?(request.requestID)
    for _ in 0..<400 {
        if host.model.taskReview?.id == request.requestID { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw SourceRecoveryHostFailure(description: title) }
        count += 1; print("PASS source-recovery-host: \(title)")
    }
    try check(host.model.taskReview?.items.first?.sourceRecoveryURL == recovery, "restored review exposes the separately retained source location")
    try check(host.model.tasks.first(where: { $0.id == request.requestID })?.status == "需要核对", "source isolation evidence never makes an interrupted operation successful")
    try check(try Data(contentsOf: recovery) == Data("isolated source evidence".utf8) && Data(contentsOf: source) == Data("new occupant at original path".utf8) && Data(contentsOf: destination) == Data("committed target".utf8), "startup and review preserve isolation original-path replacement and committed target")
    try check(try Data(contentsOf: journalURL) == bytes, "review never replays or rewrites source isolation evidence")
    return count
}
