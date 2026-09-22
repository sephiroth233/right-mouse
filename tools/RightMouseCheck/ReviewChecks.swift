import Foundation
import Darwin
import RightMouseCore

private struct ReviewCheckFailure: Error, CustomStringConvertible {
    let description: String
}

func runReviewChecks() throws -> Int {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: fixture) }

    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw ReviewCheckFailure(description: name) }
        count += 1
        print("PASS review: \(name)")
    }
    func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch {
            count += 1
            print("PASS review: \(name)")
            return
        }
        throw ReviewCheckFailure(description: "unexpected acceptance: \(name)")
    }

    let loose = fixture.appendingPathComponent("loose")
    try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard chmod(loose.path, 0o770) == 0 else { throw POSIXError(.EIO) }
    try rejects("managed directory rejects group-writable mode") { try PrivateFileIO.ensureDirectory(loose) }
    guard chmod(loose.path, 0o700) == 0 else { throw POSIXError(.EIO) }
    try PrivateFileIO.ensureDirectory(loose)
    try check(true, "managed private directory accepts owner-only mode")

    let ledgerDirectory = fixture.appendingPathComponent("Ledger")
    let ledger = try CommandLedger(directory: ledgerDirectory)
    let context = ActionContext(entryPoint: .container,
                                container: FileReference(url: fixture, kindHint: .directory),
                                selection: [])
    let request = CommandRequest(context: context, action: .copyText(format: .path))
    _ = try ledger.accept(request)

    let corruptURL = ledgerDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try PrivateFileIO.write(Data("not-json".utf8), to: corruptURL)
    var scan = try ledger.scanEntries()
    try check(scan.entries.count == 1 && scan.entries[0].request.requestID == request.requestID,
              "one corrupt ledger record does not hide a valid record")
    try check(scan.issues.contains(where: { $0.url.lastPathComponent == corruptURL.lastPathComponent }), "corrupt ledger record is reported")

    let validURL = ledgerDirectory.appendingPathComponent(request.requestID.uuidString + ".json")
    var futureObject = try JSONSerialization.jsonObject(with: PrivateFileIO.read(validURL, maximumBytes: 8 * RequestValidator.maximumBytes)) as! [String: Any]
    futureObject["schemaVersion"] = 2
    let futureURL = ledgerDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try PrivateFileIO.write(try JSONSerialization.data(withJSONObject: futureObject), to: futureURL)
    scan = try ledger.scanEntries()
    try check(scan.issues.contains(where: { $0.url.lastPathComponent == futureURL.lastPathComponent && $0.message.contains("版本") }),
              "future ledger schema is isolated")

    let linkURL = ledgerDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: validURL)
    scan = try ledger.scanEntries()
    try check(scan.issues.contains(where: { $0.url.lastPathComponent == linkURL.lastPathComponent }), "ledger symlink is rejected and reported")

    let oversizedURL = ledgerDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try PrivateFileIO.write(Data(repeating: 0x20, count: 8 * RequestValidator.maximumBytes + 1), to: oversizedURL)
    scan = try ledger.scanEntries()
    try check(scan.issues.contains(where: { $0.url.lastPathComponent == oversizedURL.lastPathComponent }), "oversized ledger record is rejected and reported")
    try check(scan.entries.count == 1 && scan.entries[0].request.requestID == request.requestID,
              "malicious ledger records remain isolated from valid entries")

    var mismatched = futureObject
    mismatched["schemaVersion"] = 1
    if var receipt = mismatched["receipt"] as? [String: Any] {
        receipt["requestID"] = UUID().uuidString
        mismatched["receipt"] = receipt
    }
    let mismatchURL = ledgerDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try PrivateFileIO.write(try JSONSerialization.data(withJSONObject: mismatched), to: mismatchURL)
    scan = try ledger.scanEntries()
    try check(scan.issues.contains(where: { $0.url.lastPathComponent == mismatchURL.lastPathComponent && $0.message.contains("标识") }),
              "receipt and request identifiers must agree")

    var badDigest = futureObject
    badDigest["schemaVersion"] = 1
    badDigest["digest"] = String(repeating: "0", count: 64)
    if var embeddedRequest = badDigest["request"] as? [String: Any],
       var embeddedReceipt = badDigest["receipt"] as? [String: Any] {
        let id = UUID().uuidString
        embeddedRequest["requestID"] = id
        embeddedReceipt["requestID"] = id
        badDigest["request"] = embeddedRequest
        badDigest["receipt"] = embeddedReceipt
    }
    let digestURL = ledgerDirectory.appendingPathComponent(((badDigest["request"] as! [String: Any])["requestID"] as! String) + ".json")
    try PrivateFileIO.write(try JSONSerialization.data(withJSONObject: badDigest), to: digestURL)
    scan = try ledger.scanEntries()
    try check(scan.issues.contains(where: { $0.url.lastPathComponent == digestURL.lastPathComponent && $0.message.contains("摘要") }),
              "ledger request digest is verified")

    return count
}
