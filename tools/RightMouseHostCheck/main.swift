import AppKit
import Foundation
import RightMouseCore

private struct HostCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RightMouseHostCheck {
    @MainActor
    static func main() async {
        do {
            let count = try await run()
            print("PASS: \(count) real HostController integration checks")
        } catch {
            fputs("FAIL host: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("RIGHTMOUSE_DATA_DIR", root.path, 1)
        defer { unsetenv("RIGHTMOUSE_DATA_DIR") }

        let paths = SharedPaths(root: root, isDevelopmentFallback: true)
        try paths.prepare()
        let destination = root.appendingPathComponent("fixture-destination", isDirectory: true)
        let copyDestination = root.appendingPathComponent("fixture-copy", isDirectory: true)
        let moveDestination = root.appendingPathComponent("fixture-move", isDirectory: true)
        for directory in [destination, copyDestination, moveDestination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }

        let recoveryRequest = CommandRequest(
            context: ActionContext(entryPoint: .container, container: FileReference(url: destination, kindHint: .directory), selection: []),
            action: .createFile(templateID: "txt", destination: FileReference(url: destination, kindHint: .directory), name: "recovery.txt"))
        do {
            let seed = try CommandLedger(directory: paths.operationsDirectory.appendingPathComponent("Commands"))
            _ = try seed.accept(recoveryRequest)
        }
        let corruptURL = paths.operationsDirectory.appendingPathComponent("Commands").appendingPathComponent(UUID().uuidString + ".json")
        try PrivateFileIO.write(Data("broken-ledger".utf8), to: corruptURL)

        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw HostCheckFailure(description: name) }
            count += 1
            print("PASS host: \(name)")
        }

        let host = try HostController()
        _ = host.model.save { $0.revealCreatedFile = false; $0.conflictPolicy = "skip" }
        try check(host.model.tasks.contains(where: { $0.id == recoveryRequest.requestID && $0.status == "需要核对" }),
                  "startup restores an accepted request as needsReview")
        try check(host.model.notice?.contains("1 条操作记录损坏") == true,
                  "one corrupt ledger is reported without hiding valid recovery")
        try check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("recovery.txt").path),
                  "recovery does not replay an uncertain file mutation")

        let txtID = try await performAndWait(host, action: "createFile:txt", files: [], destination: destination)
        try check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("未命名.txt").path), "interactive TXT creation uses real host")
        try check(try receipt(paths, txtID).status == .completed, "TXT receipt reaches completed")

        let jsonID = try await performAndWait(host, action: "createFile:json", files: [], destination: destination)
        let jsonURL = destination.appendingPathComponent("未命名.json")
        try check((try? Data(contentsOf: jsonURL)) == Data("{}\n".utf8), "interactive JSON creation preserves template bytes")
        try check(try receipt(paths, jsonID).itemResults.count == 1, "JSON receipt contains an item result")

        let duplicateID = UUID()
        let duplicateRequest = CommandRequest(
            context: ActionContext(entryPoint: .container, container: FileReference(url: destination, kindHint: .directory), selection: []),
            action: .createFile(templateID: "txt", destination: FileReference(url: destination, kindHint: .directory), name: "dedupe.txt"),
            requestID: duplicateID)
        host.submit(duplicateRequest, interactive: true)
        _ = try await wait(host, id: duplicateID)
        host.submit(duplicateRequest, interactive: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        let dedupeMatches = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("dedupe") }
        try check(dedupeMatches.count == 1, "same request ID and content does not execute twice")
        try check(try receipt(paths, duplicateID).status == .completed, "duplicate request republishes terminal receipt")

        let source = root.appendingPathComponent("copy-source.txt")
        try Data("copy-me".utf8).write(to: source)
        let copyID = UUID()
        host.submit(transferRequest(id: copyID, source: source, destination: copyDestination, mode: .copy), interactive: true)
        _ = try await wait(host, id: copyID)
        try check(FileManager.default.fileExists(atPath: source.path) && (try? Data(contentsOf: copyDestination.appendingPathComponent(source.lastPathComponent))) == Data("copy-me".utf8),
                  "real host copy preserves source and bytes")
        try check(try receipt(paths, copyID).itemResults.first?.status == "success", "copy receipt reports success")

        let moveSource = root.appendingPathComponent("move-source.txt")
        try Data("move-me".utf8).write(to: moveSource)
        let moveID = UUID()
        host.submit(transferRequest(id: moveID, source: moveSource, destination: moveDestination, mode: .move), interactive: true)
        _ = try await wait(host, id: moveID)
        try check(!FileManager.default.fileExists(atPath: moveSource.path) && FileManager.default.fileExists(atPath: moveDestination.appendingPathComponent(moveSource.lastPathComponent).path),
                  "real host move removes source only after destination commit")
        try check(try receipt(paths, moveID).status == .completed, "move receipt reaches completed")

        let cancelSource = root.appendingPathComponent("cancel-source.bin")
        try Data(repeating: 0x5a, count: 8 * 1024 * 1024).write(to: cancelSource)
        let cancelID = UUID()
        host.submit(transferRequest(id: cancelID, source: cancelSource, destination: copyDestination, mode: .copy), interactive: true)
        host.model.onCancelTask?(cancelID)
        let cancelled = try await wait(host, id: cancelID)
        try check(cancelled.status == "已取消", "queued cancellation is surfaced by real host UI state")
        try check(FileManager.default.fileExists(atPath: cancelSource.path) && !FileManager.default.fileExists(atPath: copyDestination.appendingPathComponent(cancelSource.lastPathComponent).path),
                  "queued cancellation has no file side effect")
        try check(try receipt(paths, cancelID).status == .cancelled, "cancel receipt reaches cancelled")

        return count
    }

    private static func transferRequest(id: UUID, source: URL, destination: URL, mode: CommandTransferMode) -> CommandRequest {
        CommandRequest(
            context: ActionContext(entryPoint: .items, container: FileReference(url: source.deletingLastPathComponent(), kindHint: .directory), selection: [FileReference(url: source, kindHint: .file)]),
            action: .transfer(mode: mode, destination: FileReference(url: destination, kindHint: .directory), conflictPolicy: .skip),
            requestID: id)
    }

    @MainActor
    private static func performAndWait(_ host: HostController, action: String, files: [URL], destination: URL) async throws -> UUID {
        let previous = Set(host.model.tasks.map(\.id))
        host.perform(action, files: files, destination: destination)
        for _ in 0..<400 {
            if let task = host.model.tasks.first(where: { !previous.contains($0.id) }) {
                _ = try await wait(host, id: task.id)
                return task.id
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw HostCheckFailure(description: "interactive task was not registered")
    }

    @MainActor
    private static func wait(_ host: HostController, id: UUID) async throws -> TaskPresentation {
        let terminal = Set(["完成", "部分完成", "失败", "已取消", "需要核对"])
        for _ in 0..<1_000 {
            if let task = host.model.tasks.first(where: { $0.id == id }), terminal.contains(task.status) { return task }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw HostCheckFailure(description: "task \(id) timed out")
    }

    private static func receipt(_ paths: SharedPaths, _ id: UUID) throws -> CommandReceipt {
        try WireCodec.decoder().decode(CommandReceipt.self, from: PrivateFileIO.read(paths.receiptsDirectory.appendingPathComponent(id.uuidString + ".json")))
    }
}
