import Foundation
import RightMouseCore

private struct DiagnosticHostFailure: Error, CustomStringConvertible { let description: String }

@MainActor func runDiagnosticHostChecks() async throws -> Int {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("rightmouse-diagnostic-host-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = SharedPaths(root: root, isDevelopmentFallback: true)
    let host = try HostController(storagePaths: paths)
    host.model.save { $0.revealCreatedFile = false }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw DiagnosticHostFailure(description: title) }
        count += 1; print("PASS diagnostic host: \(title)")
    }
    func exported() throws -> DiagnosticLogExport {
        guard let callback = host.model.onExportDiagnostics else { throw DiagnosticHostFailure(description: "missing diagnostic callback") }
        return try callback()
    }
    func records(_ data: Data) throws -> [DiagnosticRecord] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A).map { try decoder.decode(DiagnosticRecord.self, from: Data($0)) }
    }
    func receipt(_ id: UUID) throws -> CommandReceipt {
        try WireCodec.decoder().decode(CommandReceipt.self, from: PrivateFileIO.read(paths.receiptsDirectory.appendingPathComponent(id.uuidString + ".json")))
    }
    func finished(_ id: UUID) async throws -> CommandReceipt {
        for _ in 0..<1500 {
            if let value = try? receipt(id), [.completed,.failed,.partial,.cancelled,.needsReview].contains(value.status) { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw DiagnosticHostFailure(description: "fixture command timed out")
    }
    let initial = try exported()
    let initialRecords = try records(initial.data)
    try check(initial.report.persisted && initial.report.issues.ioFailures == 0, "host diagnostic export is connected to a readable private store")
    try check(initialRecords.contains { $0.event == .hostStarted } && initialRecords.contains { $0.event == .configurationLoaded }, "host startup emits typed lifecycle events")
    try check(initialRecords.contains { $0.event == .configurationSaved }, "saved configuration emits no configuration body")

    let target = root.appendingPathComponent("private-customer-destination")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let create = CommandRequest(context: .init(entryPoint: .container, container: .init(url: target, kindHint: .directory), selection: []),
                                action: .createFile(templateID: "txt", destination: .init(url: target, kindHint: .directory), name: "confidential-invoice.txt"))
    try check(host.submit(create, interactive: true), "diagnostic fixture file command is accepted")
    let createdReceipt = try await finished(create.requestID)
    try check(createdReceipt.status == .completed, "normal operation completes with diagnostics enabled")
    let created = try records(exported().data)
    try check(!created.contains { $0.requestID != nil || $0.action != nil }, "diagnostics do not record individual operations")
    try check(!created.contains { $0.requestID == create.requestID }, "completed operations leave no diagnostic history")
    let text = String(decoding: try exported().data, as: UTF8.self)
    try check(!text.contains(root.path) && !text.contains("private-customer") && !text.contains("confidential-invoice") && !text.contains("bookmark"), "export excludes source paths target names and bookmark fields")

    let unreadable = root.appendingPathComponent("secret-no-read.txt")
    try Data("sensitive payload".utf8).write(to: unreadable)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
    let transfer = CommandRequest(context: .init(entryPoint: .items, container: nil, selection: [.init(url: unreadable, kindHint: .file)]),
                                  action: .transfer(mode: .copy, destination: .init(url: target, kindHint: .directory), conflictPolicy: .skip))
    try check(host.submit(transfer, interactive: true), "unreadable fixture reaches host execution")
    let failed = try await finished(transfer.requestID)
    try check(failed.status == .failed && failed.itemResults.first?.error?.code == .accessDenied, "real permission failure reaches item receipt as ACCESS_DENIED")
    try check(failed.itemResults.first?.error?.retryable == true, "permission repair remains a retryable failure")
    let failureEvents = try records(exported().data)
    try check(!failureEvents.contains { $0.requestID == transfer.requestID }, "failed operations use error prompts rather than diagnostic history")
    try check(!String(decoding: try exported().data, as: UTF8.self).contains("sensitive payload"), "failed operation cannot leak file contents into export")

    let missing = CommandRequest(context: .init(entryPoint: .items, container: nil, selection: [.init(url: root.appendingPathComponent("absent.txt"), kindHint: .file)]),
                                action: .transfer(mode: .copy, destination: .init(url: target, kindHint: .directory), conflictPolicy: .skip))
    host.submit(missing, interactive: true)
    let missingReceipt = try await finished(missing.requestID)
    try check(missingReceipt.itemResults.first?.error?.code == .sourceMissing, "host preserves SOURCE_MISSING on a missing source")
    try check(host.model.tasks.first { $0.id == missing.requestID }?.canRetry == false, "non-retryable structured failure hides retry action")
    let taskIDs = Set(host.model.tasks.map(\.id))
    host.model.onRetryTask?(missing.requestID)
    try check(Set(host.model.tasks.map(\.id)) == taskIDs, "direct retry callback cannot enqueue a non-retryable failure")

    let logDirectory = root.appendingPathComponent("Diagnostics")
    try FileManager.default.moveItem(at: logDirectory, to: root.appendingPathComponent("saved-diagnostics"))
    let external = root.appendingPathComponent("external-log-sentinel")
    try Data("keep-external".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: logDirectory, withDestinationURL: external)
    let second = CommandRequest(context: create.context, action: .createFile(templateID: "txt", destination: .init(url: target, kindHint: .directory), name: "after-log-failure.txt"))
    try check(host.submit(second, interactive: true), "diagnostic store failure does not reject a file command")
    let secondReceipt = try await finished(second.requestID)
    try check(secondReceipt.status == .completed, "diagnostic I/O failure does not fail file mutation")
    let unavailable = try exported()
    try check(unavailable.report.issues.ioFailures > 0 && unavailable.data.isEmpty, "unsafe diagnostic store reports failure instead of exporting external bytes")
    try check(try Data(contentsOf: external) == Data("keep-external".utf8), "diagnostic append never modifies symlink target")
    return count
}
