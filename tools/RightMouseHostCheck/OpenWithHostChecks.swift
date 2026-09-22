import Foundation
import RightMouseCore

private struct OpenWithHostCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Exercises the real HostController admission, ledger, planner, picker branch,
/// and receipt transitions. Only the final OS application-open boundary is
/// replaced with a recorder, so these checks never launch an installed app.
@MainActor
func runOpenWithHostChecks() async throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw OpenWithHostCheckFailure(description: name) }
        count += 1
        print("PASS open-with-host: \(name)")
    }

    let requestedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-open-with-host-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
    let chosenProject = root.appendingPathComponent("chosen-project", isDirectory: true)
    for directory in [firstDirectory, secondDirectory, chosenProject] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let firstFile = firstDirectory.appendingPathComponent("first.swift")
    let peerFile = firstDirectory.appendingPathComponent("peer.swift")
    let crossDirectoryFile = secondDirectory.appendingPathComponent("second.swift")
    for file in [firstFile, peerFile, crossDirectoryFile] { try Data(file.lastPathComponent.utf8).write(to: file) }

    func paths(_ suffix: String) throws -> SharedPaths {
        let storage = root.appendingPathComponent("storage-\(suffix)", isDirectory: true)
        let value = SharedPaths(root: storage, isDevelopmentFallback: true)
        try value.prepare()
        return value
    }
    func request(_ urls: [URL], integrationID: String = "vscode") -> CommandRequest {
        CommandRequest(
            context: ActionContext(entryPoint: .items, container: nil, selection: urls.map { FileReference(url: $0, kindHint: .file) }),
            action: .openWith(integrationID: integrationID, mode: .files))
    }
    func wait(_ paths: SharedPaths, id: UUID) async throws -> CommandReceipt {
        let entryURL = paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(id.uuidString + ".json")
        let terminal: Set<ReceiptStatus> = [.completed, .failed, .cancelled, .needsReview, .rejected]
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: entryURL.path) {
                let entry = try WireCodec.decoder().decode(LedgerEntry.self, from: PrivateFileIO.read(entryURL, maximumBytes: 8 * RequestValidator.maximumBytes))
                if terminal.contains(entry.receipt.status) { return entry.receipt }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw OpenWithHostCheckFailure(description: "request \(id) timed out")
    }

    // Cross-directory input enters exactly one picker and delivers only the
    // selected project directory to the injected OS boundary.
    do {
        let storage = try paths("cross-directory")
        var pickerCalls = 0
        var deliveries: [[URL]] = []
        let host = try HostController(storagePaths: storage, projectDirectoryPicker: {
            pickerCalls += 1; return chosenProject
        }, openApplication: { urls, _ in deliveries.append(urls) })
        let command = request([firstFile, crossDirectoryFile])
        try check(host.submit(command, interactive: true), "cross-directory request is admitted")
        let receipt = try await wait(storage, id: command.requestID)
        try check(receipt.status == .completed, "cross-directory request completes after project choice")
        try check(pickerCalls == 1, "cross-directory request presents one project picker")
        try check(deliveries == [[chosenProject]], "cross-directory request makes one OS delivery containing only the chosen project")
        try check(host.model.tasks.allSatisfy { $0.id != command.requestID }, "successful open-with request does not create a file-operation task row")
    }

    // Cancelling the only picker is a terminal cancellation with no launch.
    do {
        let storage = try paths("cancel")
        var pickerCalls = 0
        var launchCalls = 0
        let host = try HostController(storagePaths: storage, projectDirectoryPicker: {
            pickerCalls += 1; return nil
        }, openApplication: { _, _ in launchCalls += 1 })
        let command = request([firstFile, crossDirectoryFile])
        try check(host.submit(command, interactive: true), "cancelled project choice request is admitted")
        let receipt = try await wait(storage, id: command.requestID)
        try check(receipt.status == .cancelled && receipt.error?.code == .cancelled, "picker cancellation is persisted as cancelled")
        try check(pickerCalls == 1 && launchCalls == 0, "picker cancellation performs no OS launch")
    }

    // File-preserving plans bypass the picker and reach the boundary once.
    do {
        let storage = try paths("file-plans")
        var pickerCalls = 0
        var deliveries: [[URL]] = []
        let host = try HostController(storagePaths: storage, projectDirectoryPicker: {
            pickerCalls += 1; return chosenProject
        }, openApplication: { urls, _ in deliveries.append(urls) })
        let single = request([firstFile])
        try check(host.submit(single, interactive: true), "single-file request is admitted")
        let singleReceipt = try await wait(storage, id: single.requestID)
        try check(singleReceipt.status == .completed, "single-file request completes")
        let peers = request([firstFile, peerFile])
        try check(host.submit(peers, interactive: true), "same-directory file request is admitted")
        let peersReceipt = try await wait(storage, id: peers.requestID)
        try check(peersReceipt.status == .completed, "same-directory file request completes")
        try check(pickerCalls == 0, "single and same-directory files bypass the project picker")
        try check(deliveries == [[firstFile], [firstFile, peerFile]], "single and same-directory files preserve file URL delivery")
    }

    // A picker contract violation is rejected before the OS boundary.
    do {
        let storage = try paths("invalid-picker")
        var launchCalls = 0
        let host = try HostController(storagePaths: storage, projectDirectoryPicker: { firstFile }, openApplication: { _, _ in launchCalls += 1 })
        let command = request([firstFile, crossDirectoryFile])
        try check(host.submit(command, interactive: true), "invalid picker result request is admitted")
        let receipt = try await wait(storage, id: command.requestID)
        try check(receipt.status == .failed && receipt.error?.code == .invalidDestination, "picker file result is persisted as invalid destination")
        try check(launchCalls == 0, "picker file result is rejected before OS launch")
    }

    // An error returned by the OS boundary must never become a success receipt.
    do {
        let storage = try paths("launcher-failure")
        var launchCalls = 0
        let host = try HostController(storagePaths: storage, projectDirectoryPicker: { chosenProject }, openApplication: { _, _ in
            launchCalls += 1
            throw CommandFailure(.appUnavailable, "fixture launcher refused the request")
        })
        let command = request([firstFile])
        try check(host.submit(command, interactive: true), "launcher-failure request is admitted")
        let receipt = try await wait(storage, id: command.requestID)
        try check(launchCalls == 1 && receipt.status == .failed && receipt.error?.code == .appUnavailable, "launcher failure is persisted as failed without false success")
    }

    // A recent-destination token is authoritative. Its request URL is only a
    // display hint and must never substitute another directory at that path.
    do {
        let storage = try paths("recent-directory")
        var deliveries: [[URL]] = []
        let host = try HostController(storagePaths: storage, projectDirectoryPicker: { nil }, openApplication: { urls, _ in deliveries.append(urls) })
        try check(host.model.rememberDestination(firstDirectory), "recent destination A is persisted with a security-scoped bookmark")
        guard let recent = host.model.configuration.recentDestinations.first(where: { $0.path == firstDirectory.standardizedFileURL.path }) else {
            throw OpenWithHostCheckFailure(description: "recent destination A was not retained")
        }
        let misleadingContainer = FileReference(url: secondDirectory, kindHint: .directory, bookmarkToken: recent.id)
        let command = CommandRequest(
            context: ActionContext(entryPoint: .container, container: misleadingContainer, selection: []),
            action: .openWith(integrationID: "vscode", mode: .directory))
        try check(host.submit(command, interactive: true), "recent-token directory request is admitted")
        let receipt = try await wait(storage, id: command.requestID)
        try check(receipt.status == .completed, "recent-token directory request completes")
        try check(deliveries.count == 1, "recent-token directory request reaches the OS boundary once")
        let delivered = deliveries[0][0].resolvingSymlinksInPath().standardizedFileURL
        try check(try DirectoryIdentity.read(delivered) == DirectoryIdentity.read(firstDirectory), "recent bookmark resolves to directory A identity")
        try check(try DirectoryIdentity.read(delivered) != DirectoryIdentity.read(secondDirectory), "recent bookmark never delivers misleading existing directory B")
    }

    // A custom integration reports only that URLs were handed to the app.
    do {
        let storage = try paths("custom-notice")
        var deliveries: [[URL]] = []
        let host = try HostController(storagePaths: storage, projectDirectoryPicker: { nil }, openApplication: { urls, _ in deliveries.append(urls) })
        try check(host.model.save { configuration in
            configuration.integrations.append(.init(id: "fixture-custom", name: "Custom Fixture", bundleID: "example.fixture", adapterType: "urls"))
        }, "custom URL integration is saved")
        let command = request([firstFile, crossDirectoryFile], integrationID: "fixture-custom")
        try check(host.submit(command, interactive: true), "custom URL request is admitted")
        let customReceipt = try await wait(storage, id: command.requestID)
        try check(customReceipt.status == .completed, "custom URL request completes after boundary acceptance")
        try check(deliveries == [[firstFile, crossDirectoryFile]], "custom integration receives the standard URL batch once")
        try check(host.model.notice == "已将所选项目交给 Custom Fixture。", "custom completion notice promises only delivery to the application")
    }

    return count
}
