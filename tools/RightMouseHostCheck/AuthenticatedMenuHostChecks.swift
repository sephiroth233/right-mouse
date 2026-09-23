import AppKit
import Foundation
import RightMouseCore

private struct AuthenticatedMenuFailure: Error { let message: String }

@MainActor func runAuthenticatedMenuHostChecks() async throws -> Int {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("rightmouse-full-menu-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let paths = SharedPaths(root: root.appendingPathComponent("state"), isDevelopmentFallback: true)
    try paths.prepare()
    let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
    for directory in [source, target] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    var opened: [URL] = [], openedID = "", confirmations = 0, checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AuthenticatedMenuFailure(message: message) }
        checks += 1; print("PASS authenticated-menu: \(message)")
    }
    let host = try HostController(storagePaths: paths, openApplication: { urls, integration in
        opened = urls; openedID = integration.id
    }, pasteboard: board, allowsLocalFinderRequests: true, confirmLocalFinderRequest: { _, _ in confirmations += 1; return false })
    let customFile = source.appendingPathComponent("custom.txt")
    let bytes = Data("custom template\nunchanged bytes\n".utf8)
    try bytes.write(to: customFile)
    let template = try host.model.templateStore.importTemplate(from: customFile, name: "Custom template")
    let favorite = SavedLocation(name: "Target", path: target.path,
        bookmarkData: try target.bookmarkData(options: .withoutImplicitSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), securityScoped: false)
    let roundTrip = try WireCodec.decoder().decode(SavedLocation.self, from: WireCodec.encoder().encode(favorite))
    try check(try roundTrip.resolve().standardizedFileURL.path == target.standardizedFileURL.path, "ordinary local bookmark survives persistence")
    var invalidBookmark = favorite; invalidBookmark.bookmarkData = Data("invalid".utf8)
    do { _ = try invalidBookmark.resolve(); throw AuthenticatedMenuFailure(message: "invalid bookmark accepted") }
    catch is AuthenticatedMenuFailure { throw AuthenticatedMenuFailure(message: "invalid bookmark accepted") }
    catch { try check(true, "invalid ordinary bookmark never falls back to stored path") }
    let app = AppIntegration(id: "custom-editor", name: "Custom editor", bundleID: "test.editor")
    try check(host.model.save { value in
        value.revealCreatedFile = false; value.templates.append(template); value.favorites.append(favorite); value.integrations.append(app)
    }, "fixture configuration saved")
    func context(_ directory: URL, files: [URL] = []) -> ActionContext {
        ActionContext(entryPoint: files.isEmpty ? .container : .items,
            container: FileReference(url: directory, kindHint: .directory), selection: files.map { FileReference(url: $0, kindHint: .file) })
    }
    func request(_ action: CommandAction, _ context: ActionContext) -> CommandRequest { CommandRequest(context: context, action: action) }
    func send(_ request: CommandRequest) throws -> Bool { host.receiveAuthenticatedFinderData(try AuthenticatedFinderRequest.encode(request)) }
    func receipt(_ id: UUID) async throws -> CommandReceipt {
        for _ in 0..<1000 {
            if let data = try? Data(contentsOf: paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(id.uuidString + ".json")),
               let entry = try? WireCodec.decoder().decode(LedgerEntry.self, from: data),
               [.completed, .failed, .partial, .cancelled, .needsReview].contains(entry.receipt.status) { return entry.receipt }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AuthenticatedMenuFailure(message: "receipt timeout")
    }
    func snapshot() throws -> LocalFinderMenuState { try LocalFinderMenuState.decode(host.authenticatedMenuState()) }
    let state = try snapshot()
    try check(state.configuration.templates.contains { $0.id == template.id } && state.configuration.integrations.contains { $0.id == app.id }
        && state.configuration.favorites.contains { $0.id == favorite.id }, "authenticated snapshot contains custom display entries")
    let serialized = String(decoding: host.authenticatedMenuState(), as: UTF8.self)
    try check(!serialized.contains("bookmarkData") && !serialized.contains("applicationPath") && !serialized.contains("resourceName")
        && !serialized.contains("custom template"), "snapshot excludes authority and template contents")
    var creation = request(.createFile(templateID: template.id, destination: nil, name: "result.txt"), context(target))
    creation.action = .createFile(templateID: template.id, destination: creation.context.container, name: "result.txt")
    try check(try send(creation), "custom template request accepted")
    let created = try await receipt(creation.requestID)
    try check(created.status == .completed && (try Data(contentsOf: target.appendingPathComponent("result.txt"))) == bytes,
              "custom template creates exact bytes")
    let open = request(.openWith(integrationID: app.id, mode: .files), context(source, files: [customFile]))
    try check(try send(open), "custom application request accepted")
    let openResult = try await receipt(open.requestID)
    try check(openResult.status == .completed && opened == [customFile] && openedID == app.id, "configured application receives captured files")
    let destination = FileReference(refID: favorite.id, url: target, kindHint: .directory, bookmarkToken: favorite.id)
    let copy = request(.transfer(mode: .copy, destination: destination, conflictPolicy: .ask), context(source, files: [customFile]))
    try check(try send(copy), "favorite copy accepted")
    let copied = try await receipt(copy.requestID)
    try check(copied.status == .completed && (try Data(contentsOf: target.appendingPathComponent(customFile.lastPathComponent))) == bytes,
              "favorite copy resolves host bookmark and copies bytes")
    let moveFile = source.appendingPathComponent("move.txt"); try bytes.write(to: moveFile)
    let move = request(.transfer(mode: .move, destination: destination, conflictPolicy: .ask), context(source, files: [moveFile]))
    try check(try send(move), "favorite move accepted")
    let moved = try await receipt(move.requestID)
    try check(moved.status == .completed && !fm.fileExists(atPath: moveFile.path) && fm.fileExists(atPath: target.appendingPathComponent("move.txt").path), "favorite move completes")
    let cutFile = source.appendingPathComponent("cut.txt"); try bytes.write(to: cutFile)
    let cut = request(.stageMove, context(source, files: [cutFile]))
    try check(try send(cut), "authenticated cut accepted")
    _ = try await receipt(cut.requestID)
    guard let pending = try snapshot().pendingMove else { throw AuthenticatedMenuFailure(message: "missing pending snapshot") }
    try check(pending.count == 1 && fm.fileExists(atPath: cutFile.path), "cut snapshot available without moving source")
    let pasteContext = context(target)
    let paste = request(.pasteMove(pendingToken: pending.token, destination: pasteContext.container, conflictPolicy: .ask), pasteContext)
    try check(try send(paste), "authenticated paste accepted")
    let pasted = try await receipt(paste.requestID)
    try check(pasted.status == .completed && !fm.fileExists(atPath: cutFile.path)
        && (try Data(contentsOf: target.appendingPathComponent("cut.txt"))) == bytes && snapshot().pendingMove == nil,
        "paste moves original bytes and clears consumed session")
    try check(try send(paste), "duplicate paste returns ledger receipt after token consumption")
    try check(try !send(request(.pasteMove(pendingToken: pending.token, destination: pasteContext.container, conflictPolicy: .ask), pasteContext)), "consumed token cannot start a second paste")
    let cutAgain = request(.stageMove, context(source, files: [customFile]))
    try check(try send(cutAgain), "new cut accepted")
    _ = try await receipt(cutAgain.requestID)
    let oldPending = try snapshot().pendingMove!
    board.clearContents(); board.setString("another clipboard owner", forType: .string)
    try check(try snapshot().pendingMove == nil, "clipboard replacement removes pending menu state")
    try check(try !send(request(.pasteMove(pendingToken: oldPending.token, destination: pasteContext.container, conflictPolicy: .ask), pasteContext)), "clipboard replacement rejects old paste")
    let forged = FileReference(refID: favorite.id, url: source, kindHint: .directory, bookmarkToken: favorite.id)
    try check(try !send(request(.transfer(mode: .copy, destination: forged, conflictPolicy: .ask), context(source, files: [customFile]))), "favorite token with forged path rejected")
    try check(try !send(request(.transfer(mode: .copy, destination: FileReference(url: target, kindHint: .directory), conflictPolicy: .ask), context(source, files: [customFile]))), "unconfigured direct transfer target rejected")
    try check(try !send(request(.createFile(templateID: template.id, destination: FileReference(url: source, kindHint: .directory), name: nil), context(target))), "creation outside captured context rejected")
    _ = host.model.save { $0.integrations.removeAll { $0.id == app.id }; $0.templates.removeAll { $0.id == template.id }; $0.favorites.removeAll() }
    try check(try !send(request(.openWith(integrationID: app.id, mode: .files), context(source, files: [customFile]))), "cached removed application rejected")
    try check(try !send(request(.createFile(templateID: template.id, destination: pasteContext.container, name: nil), pasteContext)), "cached removed template rejected")
    try check(try !send(request(.transfer(mode: .copy, destination: destination, conflictPolicy: .ask), context(source, files: [customFile]))), "cached removed favorite rejected")
    _ = host.model.save { $0.actions.removeAll { $0.commandType == "stageMove" } }
    try check(try !send(request(.stageMove, context(source, files: [customFile]))), "removed action cannot run from stale menu")
    var externalRejected = false
    do { _ = try LocalFinderRequest.encode(creation, localModeEnabled: true) } catch { externalRejected = true }
    try check(externalRejected && confirmations == 0, "expanded XPC capabilities do not widen external URL entry")
    let expired = CommandRequest(context: context(target), action: .createFile(templateID: "txt", destination: nil, name: nil), now: Date().addingTimeInterval(-300))
    try check(!host.receiveAuthenticatedFinderData(try WireCodec.encoder().encode(expired)), "expired full JSON request rejected")
    let many = request(.copyText(format: .path), context(source, files: (0..<129).map { source.appendingPathComponent("file-\($0)") }))
    try check(!host.receiveAuthenticatedFinderData(try WireCodec.encoder().encode(many)), "full JSON selection is bounded to 128")
    try check(!host.receiveAuthenticatedFinderData(Data(repeating: 65, count: AuthenticatedFinderRequest.maximumBytes + 1)), "full JSON request size bounded before parsing")
    _ = host.model.save { $0.integrations.append(AppIntegration(id: "disabled", name: "Disabled", bundleID: "test.disabled", enabled: false)) }
    try check(try !send(request(.openWith(integrationID: "disabled", mode: .files), context(source, files: [customFile]))), "disabled custom integration rejected")
    host.model.isReadOnly = true
    try check(try !snapshot().configuration.available && !send(request(.copyText(format: .path), context(source, files: [customFile]))), "read-only configuration hides menu and rejects full commands")
    var menuReads = 0, deliveries = 0
    let session = FinderXPCSession(readMenu: { reply in menuReads += 1; reply(Data("state".utf8)) }, receive: { _, reply in deliveries += 1; reply(true) })
    var read = Data()
    session.menuState { read = $0 }
    try check(read.isEmpty && menuReads == 0, "menu state cannot be read before handshake")
    let ready = FinderXPCSession(readMenu: { reply in menuReads += 1; reply(Data("state".utf8)) }, receive: { _, reply in deliveries += 1; reply(true) })
    ready.handshake(UUID().uuidString) { _ in }
    ready.menuState { read = $0 }
    try check(read == Data("state".utf8) && menuReads == 1, "authenticated menu read succeeds once")
    ready.menuState { read = $0 }
    ready.perform(Data()) { _ in }
    try check(read.isEmpty && menuReads == 1 && deliveries == 0, "menu read consumes connection and cannot perform")
    return checks
}
