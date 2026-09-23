import Foundation
import RightMouseCore

private struct RetentionStartupFailure: Error, CustomStringConvertible { let description: String }

/// Also run with -O: the app's first-launch directory URL retains a non-directory
/// hint in optimized builds, unlike a probe reopening an already existing layout.
@MainActor func runRetentionStartupChecks() async throws -> Int {
    // scripts/check-host.sh sets cwd to the repository before this entry point.
    // Match the real app's workspace data override. Foundation may canonicalize
    // /var temporary-directory aliases and erase the URL hint difference.
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("rightmouse-retention-startup-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    var count = 0, failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        count += 1
        if condition { print("PASS retention-startup: \(name)") }
        else { failures.append(name); print("FAIL retention-startup: \(name)") }
    }
    do {
        let paths = SharedPaths(root: base.appendingPathComponent("explicit-data"))
        try paths.prepare()
        let before = URL(fileURLWithPath: paths.operationsDirectory.appendingPathComponent("Commands").path, isDirectory: false)
        let ledger = try CommandLedger(directory: before)
        let after = paths.operationsDirectory.appendingPathComponent("Commands", isDirectory: true)
        check(!before.hasDirectoryPath && after.hasDirectoryPath && before.standardizedFileURL.path == after.standardizedFileURL.path,
              "fixture explicitly reproduces equal filesystem paths with different directory hints")
        let report = OperationRetention(paths: paths, ledger: ledger).prune()
        check(report.scannedRequests == 0 && report.removedRecords == 0 && report.issues == 0,
              "explicit non-directory Commands URL causes no false recovery issue")
    }
    let root = base.appendingPathComponent("host-data", isDirectory: true)
    let paths = SharedPaths(root: root, privateRoot: root.appendingPathComponent("Host", isDirectory: true), isDevelopmentFallback: true)
    // Do not prepare or inspect Commands before HostController constructs its URL.
    var host: HostController? = try HostController(storagePaths: paths)
    check(host!.model.retentionSummary?.contains("有 1 处") == false && host!.model.retentionSummary?.contains("正常操作不保留历史") == true,
          "real fresh HostController startup reports no uncertain retention records")
    let export = try host!.model.onExportDiagnostics!()
    let events = try String(decoding: export.data, as: UTF8.self).split(separator: "\n").map { line -> String in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        return object["event"] as? String ?? ""
    }
    check(events == ["hostStarted", "configurationLoaded"],
          "fresh host diagnostic export has only startup and configuration events, no false recoveryDetected")
    let commands = paths.operationsDirectory.appendingPathComponent("Commands")
    check(try FileManager.default.contentsOfDirectory(atPath: commands.path) == ["host.lock"] && host!.model.tasks.isEmpty,
          "fresh startup performs no operation and leaves only its private ledger lock")
    weak var previous = host; host = nil
    for _ in 0..<100 { if previous == nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    guard previous == nil else { throw RetentionStartupFailure(description: "startup fixture host did not release its ledger") }
    previous = nil
    guard failures.isEmpty else { throw RetentionStartupFailure(description: failures.joined(separator: "; ")) }
    return count
}
