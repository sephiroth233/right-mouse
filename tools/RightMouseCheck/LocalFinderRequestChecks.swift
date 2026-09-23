import Foundation
import RightMouseCore

private struct LocalFinderCheckFailure: Error, CustomStringConvertible { let description: String }

func runLocalFinderRequestChecks() throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw LocalFinderCheckFailure(description: name) }
        count += 1; print("PASS local-finder: \(name)")
    }
    func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; print("PASS local-finder: \(name)"); return }
        throw LocalFinderCheckFailure(description: "unexpected acceptance: \(name)")
    }
    let now = Date()
    let directory = FileReference(url: URL(fileURLWithPath: "/fixture/folder"), kindHint: .directory)
    let file = FileReference(url: URL(fileURLWithPath: "/fixture/folder/item.txt"), kindHint: .file)
    let context = ActionContext(entryPoint: .items, container: directory, selection: [file])
    func request(_ action: CommandAction, context value: ActionContext? = nil) -> CommandRequest {
        CommandRequest(context: value ?? context, action: action, now: now)
    }
    func roundTrip(_ action: CommandAction) throws -> CommandRequest {
        let value = request(action)
        return try LocalFinderRequest.decode(LocalFinderRequest.encode(value, localModeEnabled: true), localModeEnabled: true, now: now)
    }

    try check(try roundTrip(.createFile(templateID: "txt", destination: nil, name: nil)).action == .createFile(templateID: "txt", destination: nil, name: nil), "built-in create request round trips")
    try check(try roundTrip(.transfer(mode: .copy, destination: nil, conflictPolicy: .ask)).action.type == "transfer", "interactive transfer round trips")
    try check(try roundTrip(.stageMove).action == .stageMove, "stage move round trips")
    try check(try roundTrip(.openWith(integrationID: "terminal", mode: .directory)).action.type == "openWith", "built-in integration round trips")
    try check(try roundTrip(.copyText(format: .shellPath)).action == .copyText(format: .shellPath), "copy text round trips")
    let validURL = try LocalFinderRequest.encode(request(.stageMove), localModeEnabled: true)
    try rejects("disabled build cannot encode") { _ = try LocalFinderRequest.encode(request(.stageMove), localModeEnabled: false) }
    try rejects("disabled build cannot decode") { _ = try LocalFinderRequest.decode(validURL, localModeEnabled: false, now: now) }

    for bad in [
        "rightmouse://user@local-action?payload=x",
        "rightmouse://local-action:9?payload=x",
        "rightmouse://local-action/path?payload=x",
        "rightmouse://local-action?payload=x&extra=y",
        "rightmouse://local-action?payload=x#fragment"
    ] { try rejects("strict URL structure rejects \(bad)") { _ = try LocalFinderRequest.decode(URL(string: bad)!, localModeEnabled: true, now: now) } }
    try rejects("noncanonical padded base64url rejected") { _ = try LocalFinderRequest.decode(URL(string: validURL.absoluteString + "=")!, localModeEnabled: true, now: now) }
    let noncanonicalJSON = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: WireCodec.encoder().encode(request(.stageMove))), options: [.prettyPrinted])
    let noncanonicalPayload = noncanonicalJSON.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    try rejects("semantically equal noncanonical JSON rejected") { _ = try LocalFinderRequest.decode(URL(string: "rightmouse://local-action?payload=\(noncanonicalPayload)")!, localModeEnabled: true, now: now) }
    let oversized = URL(string: "rightmouse://local-action?payload=" + String(repeating: "A", count: LocalFinderRequest.maximumURLBytes))!
    try rejects("48 KiB URL limit enforced") { _ = try LocalFinderRequest.decode(oversized, localModeEnabled: true, now: now) }

    var bookmarked = file; bookmarked.bookmarkToken = UUID()
    let bookmarkContext = ActionContext(entryPoint: .items, container: directory, selection: [bookmarked])
    try rejects("bookmark tokens rejected") { _ = try LocalFinderRequest.encode(request(.stageMove, context: bookmarkContext), localModeEnabled: true) }
    let many = ActionContext(entryPoint: .items, container: directory, selection: (0..<129).map { FileReference(url: URL(fileURLWithPath: "/fixture/\($0)")) })
    try rejects("selection capped at 128") { _ = try LocalFinderRequest.encode(request(.stageMove, context: many), localModeEnabled: true) }
    try rejects("unlisted built-in template rejected") { _ = try LocalFinderRequest.encode(request(.createFile(templateID: "yaml", destination: nil, name: nil)), localModeEnabled: true) }
    try rejects("paste move rejected") { _ = try LocalFinderRequest.encode(request(.pasteMove(pendingToken: UUID(), destination: nil, conflictPolicy: .ask)), localModeEnabled: true) }
    try rejects("transfer destination rejected") { _ = try LocalFinderRequest.encode(request(.transfer(mode: .move, destination: directory, conflictPolicy: .ask)), localModeEnabled: true) }
    try rejects("transfer non-ask policy rejected") { _ = try LocalFinderRequest.encode(request(.transfer(mode: .copy, destination: nil, conflictPolicy: .skip)), localModeEnabled: true) }
    try rejects("custom integration rejected") { _ = try LocalFinderRequest.encode(request(.openWith(integrationID: "custom", mode: .files)), localModeEnabled: true) }
    var stale = request(.stageMove); stale.createdAt = now.addingTimeInterval(-300); stale.expiresAt = stale.createdAt.addingTimeInterval(120)
    let staleURL = try LocalFinderRequest.encode(stale, localModeEnabled: true)
    try rejects("decode revalidates freshness") { _ = try LocalFinderRequest.decode(staleURL, localModeEnabled: true, now: now) }
    return count
}
