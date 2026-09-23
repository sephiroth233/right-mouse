import AppKit
import RightMouseCore

private struct ServiceCheckFailure: Error { let message: String }

@MainActor func runFinderServicesChecks() async throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ServiceCheckFailure(message: message) }
        count += 1; print("PASS services: \(message)")
    }
    func rejects(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try check(rejected, message)
    }
    let root = URL(fileURLWithPath: "/private/tmp/rightmouse-services-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("untouched".utf8).write(to: source)
    let config = AppConfiguration()
    func make(_ action: String?, _ urls: [URL], _ config: AppConfiguration = AppConfiguration()) throws -> CommandRequest {
        try FinderServiceRequest.make(action: action, urls: urls, configuration: config)
    }
    try rejects("empty selection rejected") { _ = try make("copyPath", []) }
    try rejects("unknown action cannot execute commands") { _ = try make("shell:touch /tmp/unwanted", [source]) }
    try rejects("missing action rejected") { _ = try make(nil, [source]) }
    try rejects("web URL rejected") { _ = try make("copyPath", [URL(string: "https://example.com")!]) }
    try rejects("remote file host rejected") { _ = try make("copyPath", [URL(string: "file://remote/tmp/test")!]) }
    try rejects("mixed invalid input is not partially accepted") { _ = try make("copyPath", [source, URL(string: "https://example.com")!]) }
    try rejects("129 inputs rejected") { _ = try make("copyPath", Array(repeating: source, count: 129)) }
    try rejects("oversized input rejected") { _ = try make("copyPath", [URL(fileURLWithPath: "/" + String(repeating: "a", count: 70_000))]) }
    try rejects("file cannot become a new-file destination") { _ = try make("createTXT", [source]) }
    try rejects("multiple destinations rejected") { _ = try make("createMarkdown", [root, root]) }
    try rejects("terminal multi-selection rejected") { _ = try make("openTerminal", [source, source]) }
    var disabled = config
    disabled.actions[0].enabled = false
    try rejects("disabled action rejected") { _ = try make("createTXT", [root], disabled) }
    disabled = config; disabled.templates.removeAll { $0.id == "txt" }
    try rejects("removed template rejected") { _ = try make("createTXT", [root], disabled) }
    disabled = config; disabled.integrations[0].enabled = false
    try rejects("disabled integration rejected") { _ = try make("openTerminal", [root], disabled) }

    let input = NSPasteboard.withUniqueName(), output = NSPasteboard.withUniqueName()
    defer { input.releaseGlobally(); output.releaseGlobally() }
    input.writeObjects([source as NSURL])
    try check(try FinderServiceRequest.urls(from: input) == [source], "modern file URL pasteboard decoded")
    input.clearContents(); input.setString(source.path, forType: .string)
    try rejects("plain text path is not promoted to file authority") { _ = try FinderServiceRequest.urls(from: input) }
    input.clearContents(); input.setPropertyList([source.path], forType: .init("NSFilenamesPboardType"))
    try check(try FinderServiceRequest.urls(from: input) == [source], "legacy Finder filename list decoded")
    input.clearContents(); input.setPropertyList(["relative.txt"], forType: .init("NSFilenamesPboardType"))
    try rejects("relative legacy path rejected") { _ = try FinderServiceRequest.urls(from: input) }

    let paths = SharedPaths(root: root.appendingPathComponent("state"), isDevelopmentFallback: true)
    var windows = 0, opened: [String] = []
    let host = try HostController(storagePaths: paths, openApplication: { _, integration in opened.append(integration.id) }, pasteboard: output)
    host.model.save { $0.revealCreatedFile = false }
    host.showTasks = { windows += 1 }
    let provider = FinderServicesProvider()
    var dispatches = 0
    var lastRequest: CommandRequest?
    provider.onInvocation = { dispatches += 1 }
    provider.configuration = { host.model.configuration }
    provider.submit = { request in lastRequest = request; return host.submit(request, interactive: true) }
    func invoke(_ action: String, urls: [URL]) async throws {
        input.clearContents(); input.writeObjects(urls.map { $0 as NSURL })
        var error: NSString?
        provider.performAction(input, userData: action, error: &error)
        try check(error == nil, "provider accepts \(action)")
        guard let request = lastRequest else { throw ServiceCheckFailure(message: "missing submission") }
        let receiptURL = paths.receiptsDirectory.appendingPathComponent(request.requestID.uuidString + ".json")
        for _ in 0..<500 {
            if let data = try? Data(contentsOf: receiptURL), let receipt = try? WireCodec.decoder().decode(CommandReceipt.self, from: data), receipt.status == .completed { return }
            if let message = host.model.errorMessage { throw ServiceCheckFailure(message: message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ServiceCheckFailure(message: "service execution timed out")
    }
    try await invoke("createTXT", urls: [root])
    try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("未命名.txt").path), "directory service creates TXT via real host")
    try await invoke("createMarkdown", urls: [root])
    try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("未命名.md").path), "directory service creates Markdown via real host")
    try await invoke("createTXT", urls: [root])
    try check(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("未命名") && $0.hasSuffix(".txt") }.count == 2, "duplicate create uses numbered filename")
    try await invoke("copyPath", urls: [source])
    try check(output.string(forType: .string) == source.path, "service copies through isolated host pasteboard")
    try await invoke("openTerminal", urls: [root])
    try await invoke("openVSCode", urls: [source])
    try check(opened == ["terminal", "vscode"], "services use existing configured application adapters")
    try check(windows == 0 && host.model.recoveryTasks.isEmpty && host.model.errorMessage == nil, "success creates no task popup or recovery history")
    let submitted = lastRequest?.requestID
    var error: NSString?
    provider.performAction(input, userData: "invalid", error: &error)
    try check(error != nil && lastRequest?.requestID == submitted, "invalid service returns error without submission")
    try check(dispatches == 7, "invocation notification covers cold-launch suppression even for invalid input")
    try check(try Data(contentsOf: source) == Data("untouched".utf8), "input file remains unchanged")
    return count
}
