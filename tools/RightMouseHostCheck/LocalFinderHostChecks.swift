import AppKit
import Foundation
import RightMouseCore

private struct LocalFinderHostFailure: Error, CustomStringConvertible { let description: String }

/// All requests and files belong to this fixture. No UI confirmation, Finder,
/// application launch, or general pasteboard is used by these entry-point checks.
@MainActor func runLocalFinderHostChecks() async throws -> Int {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("rightmouse-local-finder-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw LocalFinderHostFailure(description: name) }
        count += 1; print("PASS local-finder-host: \(name)")
    }
    func fixture(_ name: String) throws -> (SharedPaths, URL) {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let paths = SharedPaths(root: base.appendingPathComponent("shared"), privateRoot: base.appendingPathComponent("private"), isDevelopmentFallback: true)
        try paths.prepare()
        var configuration = AppConfiguration(); configuration.revealCreatedFile = false
        try ConfigurationStore(directory: paths.configurationDirectory).save(configuration)
        let target = base.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (paths, target)
    }
    func create(_ target: URL, name: String = "created.txt", now: Date = Date()) -> CommandRequest {
        let reference = FileReference(url: target, kindHint: .directory)
        return CommandRequest(context: ActionContext(entryPoint: .container, container: reference, selection: []),
                              action: .createFile(templateID: "txt", destination: reference, name: name), now: now)
    }
    func link(_ request: CommandRequest) throws -> URL { try LocalFinderRequest.encode(request, localModeEnabled: true) }
    func commandURL(_ paths: SharedPaths, _ id: UUID) -> URL {
        paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(id.uuidString + ".json")
    }
    func commandNames(_ paths: SharedPaths) throws -> [String] {
        try fm.contentsOfDirectory(atPath: paths.operationsDirectory.appendingPathComponent("Commands").path).filter { $0.hasSuffix(".json") }
    }
    func receipt(_ paths: SharedPaths, _ id: UUID) async throws -> CommandReceipt {
        let url = paths.receiptsDirectory.appendingPathComponent(id.uuidString + ".json")
        for _ in 0..<1500 {
            if let data = try? Data(contentsOf: url), let value = try? WireCodec.decoder().decode(CommandReceipt.self, from: data),
               [.completed, .partial, .failed, .cancelled, .rejected, .needsReview].contains(value.status) { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LocalFinderHostFailure(description: "local Finder fixture request timed out")
    }
    do {
        let (paths, target) = try fixture("authenticated-xpc")
        var confirmations = 0
        let host = try HostController(storagePaths: paths, pasteboard: board, allowsLocalFinderRequests: true,
                                      confirmLocalFinderRequest: { _, _ in confirmations += 1; return false })
        let request = create(target)
        let payload = Data(try link(request).absoluteString.utf8)
        try check(host.receiveAuthenticatedFinderData(payload) && confirmations == 0, "authenticated transport enters ledger without URL confirmation")
        let completed = try await receipt(paths, request.requestID)
        try check(completed.status == .completed && fm.fileExists(atPath: target.appendingPathComponent("created.txt").path), "authenticated creation completes through existing engine")
        try check(host.receiveAuthenticatedFinderData(payload), "authenticated duplicate request returns existing receipt")
        try check(try fm.contentsOfDirectory(atPath: target.path).count == 1, "authenticated duplicate cannot create a second file")
        try check(!host.receiveLocalFinderURL(try link(request)) && confirmations == 1, "external URL still needs confirmation even for an existing authenticated request")
        let old = Data(try link(create(target, now: Date().addingTimeInterval(-300))).absoluteString.utf8)
        try check(!host.receiveAuthenticatedFinderData(old), "authenticated stale request rejected")
        try check(!host.receiveAuthenticatedFinderData(Data(repeating: 65, count: LocalFinderRequest.maximumURLBytes + 1)), "authenticated oversized payload rejected")
        try check(!host.receiveAuthenticatedFinderData(Data("not-a-request".utf8)), "authenticated malformed payload rejected")
        host.model.isReadOnly = true
        try check(!host.receiveAuthenticatedFinderData(Data(try link(create(target)).absoluteString.utf8)), "authenticated transport respects read-only mode")
    }
    do {
        var received = 0, accepted = true
        let before = FinderXPCSession { _, reply in received += 1; reply(true) }
        before.perform(Data()) { accepted = $0 }
        try check(!accepted && received == 0, "XPC perform before handshake is rejected")
        let session = FinderXPCSession { _, reply in received += 1; reply(true) }
        var response = ""
        session.handshake("bad") { response = $0 }
        try check(response.isEmpty, "XPC malformed nonce rejected")
        let nonce = UUID().uuidString
        session.handshake(nonce) { response = $0 }
        try check(response == LocalXPCIdentity.response(nonce), "XPC handshake echoes version and nonce")
        session.perform(Data()) { accepted = $0 }
        try check(accepted && received == 1, "handshaken session accepts one payload")
        session.perform(Data()) { accepted = $0 }
        try check(!accepted && received == 1, "session refuses a second operation")
        session.handshake(UUID().uuidString) { response = $0 }
        try check(response.isEmpty, "consumed session cannot be rearmed")
        let oversized = FinderXPCSession { _, reply in received += 1; reply(true) }
        oversized.handshake(UUID().uuidString) { _ in }
        oversized.perform(Data(repeating: 0, count: LocalFinderRequest.maximumURLBytes + 1)) { accepted = $0 }
        try check(!accepted && received == 1, "session size limit precedes host dispatch")
    }
    do {
        let (paths, target) = try fixture("disabled")
        var confirmations = 0
        let host = try HostController(storagePaths: paths, pasteboard: board, allowsLocalFinderRequests: false,
                                      confirmLocalFinderRequest: { _, _ in confirmations += 1; return true })
        let request = create(target)
        try check(!host.receiveLocalFinderURL(try link(request)) && confirmations == 0, "disabled local mode refuses a valid URL before confirmation")
        try check(try commandNames(paths).isEmpty && fm.contentsOfDirectory(atPath: target.path).isEmpty, "disabled mode creates neither a command ledger record nor a file")
    }
    do {
        let (paths, target) = try fixture("invalid-and-cancel")
        var confirmations = 0
        let host = try HostController(storagePaths: paths, pasteboard: board, allowsLocalFinderRequests: true,
                                      confirmLocalFinderRequest: { _, _ in confirmations += 1; return false })
        try check(!host.receiveLocalFinderURL(URL(string: "rightmouse://local-action?payload=invalid&payload=duplicate")!) && confirmations == 0,
                  "malformed external URL cannot reach confirmation")
        let expired = create(target, now: Date().addingTimeInterval(-300))
        try check(!host.receiveLocalFinderURL(try link(expired)) && confirmations == 0, "expired local request cannot reach confirmation")
        try check(try commandNames(paths).isEmpty && fm.contentsOfDirectory(atPath: target.path).isEmpty, "invalid and expired requests have no ledger or file effects")
        let cancelled = create(target)
        try check(!host.receiveLocalFinderURL(try link(cancelled)) && confirmations == 1, "user cancellation rejects the valid request")
        try check(try commandNames(paths).isEmpty && fm.contentsOfDirectory(atPath: target.path).isEmpty && fm.contentsOfDirectory(atPath: paths.receiptsDirectory.path).isEmpty,
                  "cancellation creates no ledger record file or acceptance receipt")
    }
    do {
        let (paths, target) = try fixture("confirmed")
        var confirmations = 0, cleanBeforeConfirm = false
        let request = create(target)
        let host = try HostController(storagePaths: paths, pasteboard: board, allowsLocalFinderRequests: true,
                                      confirmLocalFinderRequest: { incoming, _ in
            confirmations += 1
            if confirmations == 1 {
                cleanBeforeConfirm = incoming.requestID == request.requestID
                    && !fm.fileExists(atPath: commandURL(paths, request.requestID).path)
                    && !fm.fileExists(atPath: target.appendingPathComponent("created.txt").path)
            }
            return true
        })
        let url = try link(request)
        try check(host.receiveLocalFinderURL(url) && cleanBeforeConfirm && confirmations == 1, "explicit approval occurs before ledger acceptance or creation")
        let completed = try await receipt(paths, request.requestID)
        try check(completed.status == .completed && completed.itemResults.count == 1 && completed.itemResults[0].status == "success",
                  "approved TXT creation returns the real completed item receipt")
        let created = target.appendingPathComponent("created.txt")
        let bytes = try Data(contentsOf: created)
        let saved = try WireCodec.decoder().decode(LedgerEntry.self, from: Data(contentsOf: commandURL(paths, request.requestID)))
        try check(saved.receipt.status == .completed && completed.itemResults[0].destinationURL?.path == created.path,
                  "approved creation persists its matching private ledger and shared destination receipt")
        try check(host.receiveLocalFinderURL(url) && confirmations == 2, "repeated external request still requires explicit confirmation")
        let repeated = try await receipt(paths, request.requestID)
        try check(try repeated.revision == completed.revision && fm.contentsOfDirectory(atPath: target.path) == ["created.txt"] && Data(contentsOf: created) == bytes && commandNames(paths).count == 1,
                  "confirmed duplicate returns the same result without replaying file creation")
    }
    do {
        let (paths, target) = try fixture("reentrant")
        let outer = create(target, name: "outer.txt"), nested = create(target, name: "nested.txt")
        let nestedURL = try link(nested)
        weak var receivingHost: HostController?
        var confirmations = 0, nestedAccepted = true
        let host = try HostController(storagePaths: paths, pasteboard: board, allowsLocalFinderRequests: true,
                                      confirmLocalFinderRequest: { _, _ in
            confirmations += 1
            nestedAccepted = receivingHost?.receiveLocalFinderURL(nestedURL) ?? true
            return false
        })
        receivingHost = host
        try check(!host.receiveLocalFinderURL(try link(outer)) && !nestedAccepted && confirmations == 1,
                  "a second URL arriving inside confirmation is rejected without a nested confirmation")
        try check(try commandNames(paths).isEmpty && fm.contentsOfDirectory(atPath: target.path).isEmpty,
                  "reentrant rejection and outer cancellation leave both requests without effects")
    }
    do {
        let (paths, target) = try fixture("read-only")
        let future = Data("{\"schemaVersion\":999,\"future\":\"KEEP-UNCHANGED\"}".utf8)
        let configurationURL = ConfigurationStore(directory: paths.configurationDirectory).fileURL
        try PrivateFileIO.write(future, to: configurationURL)
        var confirmations = 0
        let host = try HostController(storagePaths: paths, pasteboard: board, allowsLocalFinderRequests: true,
                                      confirmLocalFinderRequest: { _, _ in confirmations += 1; return true })
        try check(host.model.isReadOnly && !host.receiveLocalFinderURL(try link(create(target))) && confirmations == 0,
                  "future configuration refuses the local entry point before confirmation")
        try check(try Data(contentsOf: configurationURL) == future && commandNames(paths).isEmpty && fm.contentsOfDirectory(atPath: target.path).isEmpty,
                  "read-only refusal preserves future configuration and creates no command or file")
    }
    do {
        let (paths, target) = try fixture("escaped-details")
        let source = target.appendingPathComponent("line\n目标：伪造\t\"quoted\".txt")
        let bytes = Data("fixture-source".utf8); try bytes.write(to: source)
        let request = CommandRequest(context: ActionContext(entryPoint: .items, container: nil, selection: [FileReference(url: source, kindHint: .file)]), action: .copyText(format: .path))
        var details = ""
        let host = try HostController(storagePaths: paths, pasteboard: board, allowsLocalFinderRequests: true,
                                      confirmLocalFinderRequest: { _, value in details = value; return false })
        let changeCount = board.changeCount
        try check(!host.receiveLocalFinderURL(try link(request)), "special-character path request is stopped at its injected cancellation")
        let quoted = "\"" + source.path.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        try check(details.contains("1. " + quoted) && details.contains("\\n") && details.contains("\\t") && !details.contains(source.path),
                  "confirmation renders embedded newline tab and quote as one distinguishable escaped path")
        try check(try Data(contentsOf: source) == bytes && board.changeCount == changeCount && commandNames(paths).isEmpty,
                  "cancelled path-copy confirmation leaves source bytes pasteboard and ledger unchanged")
    }
    return count
}
