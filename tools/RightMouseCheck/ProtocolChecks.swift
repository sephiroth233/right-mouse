import Foundation
import RightMouseCore

private struct ProtocolCheckFailure: Error, CustomStringConvertible { let description: String }

func runProtocolChecks() throws -> Int {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-protocol-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw ProtocolCheckFailure(description: name) }; count += 1; print("PASS protocol: \(name)")
    }
    func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch { count += 1; print("PASS protocol: \(name)"); return }
        throw ProtocolCheckFailure(description: "unexpected acceptance: \(name)")
    }
    let reference = FileReference(url: fixture, kindHint: .directory)
    let request = CommandRequest(context: ActionContext(entryPoint: .container, container: reference, selection: []), action: .createFile(templateID: "txt", destination: nil, name: nil))
    let data = try WireCodec.encoder().encode(request)
    let decoded = try RequestValidator.decode(data)
    try check(decoded.requestID == request.requestID, "wire round trip including explicit null destination")
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object["unexpected"] = true
    try rejects("unknown top-level field") { _ = try RequestValidator.decode(JSONSerialization.data(withJSONObject: object)) }
    object.removeValue(forKey: "unexpected")
    object["schemaVersion"] = true
    try rejects("boolean cannot masquerade as version 1") { _ = try RequestValidator.decode(JSONSerialization.data(withJSONObject: object)) }
    object["schemaVersion"] = 1
    object["action"] = ["type": "executeShell", "command": "echo bad"]
    try rejects("arbitrary command rejected") { _ = try RequestValidator.decode(JSONSerialization.data(withJSONObject: object)) }
    var invalid = request
    invalid.context.container?.url = URL(string: "file:///tmp?danger=1")!
    try rejects("file URL query rejected") { _ = try RequestValidator.decode(WireCodec.encoder().encode(invalid)) }
    invalid = request; invalid.context.selection = Array(repeating: reference, count: 1025)
    try rejects("selection size capped") { _ = try RequestValidator.decode(WireCodec.encoder().encode(invalid)) }
    invalid = request; invalid.context.selection = [reference, reference]
    try rejects("duplicate reference identity rejected") { _ = try RequestValidator.decode(WireCodec.encoder().encode(invalid)) }
    invalid = request; invalid.expiresAt = Date().addingTimeInterval(-1)
    try rejects("expired request rejected") { try RequestValidator.validateFresh(invalid) }
    invalid = request; invalid.createdAt = Date().addingTimeInterval(60); invalid.expiresAt = invalid.createdAt.addingTimeInterval(120)
    try rejects("future timestamp rejected") { try RequestValidator.validateFresh(invalid) }
    try rejects("dispatch URL cannot contain arguments") { _ = try RequestValidator.dispatchID(from: URL(string: "rightmouse://dispatch/\(request.requestID)?action=delete")!) }
    try check(try RequestValidator.dispatchID(from: URL(string: "rightmouse://dispatch/\(request.requestID)")!) == request.requestID, "dispatch UUID parsed")
    let ledgerURL = fixture.appendingPathComponent("Ledger")
    let ledger = try CommandLedger(directory: ledgerURL)
    let first = try ledger.accept(decoded), again = try ledger.accept(decoded)
    try check(first.isNew && !again.isNew, "accepted request deduplicated")
    invalid = decoded; invalid.action = .copyText(format: .path)
    try rejects("same ID changed body rejected") { _ = try ledger.accept(invalid) }
    try check(try ledger.accept(decoded, now: Date().addingTimeInterval(300)).isNew == false, "known expired request returns old record")
    try rejects("second host cannot acquire ledger") { _ = try CommandLedger(directory: ledgerURL) }
    let inbox = InboxStore(directory: fixture.appendingPathComponent("Inbox"))
    try inbox.enqueue(request); try inbox.enqueue(request)
    try check(try inbox.pendingIDs().count == 1, "queue resubmission is idempotent")
    let badID = UUID(), link = inbox.directory.appendingPathComponent(badID.uuidString + ".json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inbox.directory.appendingPathComponent(request.requestID.uuidString + ".json"))
    try rejects("symlink queue file rejected") { _ = try inbox.request(badID) }
    let urls = [URL(fileURLWithPath: "/tmp/.env"), URL(fileURLWithPath: "/tmp/a.tar.gz")]
    try check(PathText.format(urls, as: .stem) == ".env\na.tar", "dotfile and last extension semantics")
    try check(PathText.shellQuote("a'b\n$(touch x)") == "'a'\\''b\n$(touch x)'", "shell argument quoting preserves literal special characters")
    return count
}
