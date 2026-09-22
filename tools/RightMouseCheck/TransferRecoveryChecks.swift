import Foundation
import RightMouseCore

private struct TransferRecoveryCheckFailure: Error, CustomStringConvertible {
    let description: String
}

func runTransferRecoveryChecks() async throws -> Int {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-transfer-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: fixture) }

    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw TransferRecoveryCheckFailure(description: name) }
        count += 1
        print("PASS transfer-recovery: \(name)")
    }
    func rejects(_ name: String, _ action: () async throws -> Void) async throws {
        do { try await action() }
        catch {
            count += 1
            print("PASS transfer-recovery: \(name)")
            return
        }
        throw TransferRecoveryCheckFailure(description: "unexpected acceptance: \(name)")
    }

    let journal = fixture.appendingPathComponent("Journal")
    let source = fixture.appendingPathComponent("source.txt")
    let destination = fixture.appendingPathComponent("Destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("recovery".utf8).write(to: source)
    let operationID = UUID()
    let engine = FileTransferEngine(journalDirectory: journal)
    let result = await engine.transfer(sources: [source], to: destination, mode: .move, operationID: operationID)
    guard let goodItemID = result.items.first?.itemID else { throw TransferRecoveryCheckFailure(description: "missing transfer result") }
    let goodURL = journal.appendingPathComponent(goodItemID.uuidString + ".json")

    var scan = try await engine.scanRecoveryRecords()
    try check(scan.records.count == 1 && scan.records[0].operationID == operationID, "valid journal is readable")
    try check(scan.records[0].result?.itemID == goodItemID && scan.records[0].result?.operationID == operationID,
              "saved result IDs match its journal")

    let corruptURL = journal.appendingPathComponent(UUID().uuidString + ".json")
    try PrivateFileIO.write(Data("not-json".utf8), to: corruptURL)
    let linkURL = journal.appendingPathComponent(UUID().uuidString + ".json")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: goodURL)
    let oversizedURL = journal.appendingPathComponent(UUID().uuidString + ".json")
    try PrivateFileIO.write(Data(repeating: 0x20, count: RequestValidator.maximumBytes + 1), to: oversizedURL)

    let goodObject = try JSONSerialization.jsonObject(with: PrivateFileIO.read(goodURL)) as! [String: Any]
    func writeVariant(_ mutate: (inout [String: Any]) -> Void) throws -> URL {
        var object = goodObject
        mutate(&object)
        let url = journal.appendingPathComponent(UUID().uuidString + ".json")
        try PrivateFileIO.write(try JSONSerialization.data(withJSONObject: object), to: url)
        return url
    }
    let futureURL = try writeVariant { $0["schemaVersion"] = 2 }
    let remoteURL = try writeVariant { $0["source"] = "https://example.com/source" }
    let resultItemURL = try writeVariant {
        guard var embedded = $0["result"] as? [String: Any] else { return }
        embedded["itemID"] = UUID().uuidString
        $0["result"] = embedded
    }
    let resultOperationURL = try writeVariant {
        guard var embedded = $0["result"] as? [String: Any] else { return }
        embedded["operationID"] = UUID().uuidString
        $0["result"] = embedded
    }

    scan = try await engine.scanRecoveryRecords()
    let issueNames = Set(scan.issues.map { $0.url.lastPathComponent })
    for (url, name) in [(corruptURL, "corrupt JSON"), (linkURL, "journal symlink"), (oversizedURL, "oversized journal"),
                        (futureURL, "future schema"), (remoteURL, "remote source URL"),
                        (resultItemURL, "mismatched result item ID"), (resultOperationURL, "mismatched result operation ID")] {
        try check(issueNames.contains(url.lastPathComponent), "\(name) is isolated")
    }
    try check(scan.records.count == 1 && scan.records[0].itemID == goodItemID, "bad journals do not hide the valid journal")
    let compatibleRecords = try await engine.recoveryRecords()
    try check(compatibleRecords.count == 1, "compatibility recovery API returns valid records only")

    guard let undo = result.items.first?.undoToken else { throw TransferRecoveryCheckFailure(description: "missing same-volume undo token") }
    try await engine.undo(undo)
    scan = try await engine.scanRecoveryRecords()
    let finished = scan.records.filter { $0.result?.status == .completed }
    try check(finished.count == 2, "transfer and undo completion journals are both readable")
    try check(finished.allSatisfy { $0.result?.itemID == $0.itemID && $0.result?.operationID == $0.operationID },
              "undo completion preserves journal item and operation IDs")

    let realDirectory = fixture.appendingPathComponent("RealJournal")
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let linkedDirectory = fixture.appendingPathComponent("LinkedJournal")
    try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
    let linkedEngine = FileTransferEngine(journalDirectory: linkedDirectory)
    try await rejects("journal directory symlink is rejected") { _ = try await linkedEngine.scanRecoveryRecords() }

    return count
}
