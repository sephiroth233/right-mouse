import Foundation
import Darwin
@testable import RightMouseCore

func runFileEngineChecks() async throws -> Int {
    let passed = try await FileOperationSelfTests.run()
    for item in passed { print("PASS file-engine: \(item)") }
    return passed.count
}

/// The same fixture checks can run under CLT without XCTest by compiling with engine sources.
enum FileOperationSelfTests {
    struct Failed: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failed(description: message) }
    }
    static func run() async throws -> [String] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rightmouse-file-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var passed: [String] = []
        func fixture(_ name: String) throws -> (URL, URL, FileTransferEngine) {
            let base = root.appendingPathComponent(name)
            let src = base.appendingPathComponent("source"), dst = base.appendingPathComponent("target")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            return (src, dst, FileTransferEngine(journalDirectory: base.appendingPathComponent("journal")))
        }
        func file(_ directory: URL, _ name: String = "file.txt", _ text: String = "original") throws -> URL {
            let url = directory.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
        }
        do {
            let (src, dst, engine) = try fixture("move-undo")
            let source = try file(src)
            let result = await engine.transfer(sources: [source], to: dst, mode: .move)
            try require(result.completedCount == 1, "Same-volume move failed: \(result.items)")
            try require(!fm.fileExists(atPath: source.path), "Move kept source unexpectedly")
            let records = try await engine.recoveryRecords()
            try require(records.first?.itemID == result.items[0].itemID && records.first?.result?.itemID == result.items[0].itemID, "Result and recovery journal item IDs differ")
            guard let token = result.items[0].undoToken else { throw Failed(description: "Missing undo token") }
            try await engine.undo(token)
            try require(try String(contentsOf: source, encoding: .utf8) == "original", "Undo changed content")
            passed.append("same-volume move and conditional undo")
        }
        do {
            let (src, dst, engine) = try fixture("undo-occupied")
            let source = try file(src)
            let result = await engine.transfer(sources: [source], to: dst, mode: .move)
            _ = try file(src, "file.txt", "replacement")
            do { try await engine.undo(result.items[0].undoToken!); throw Failed(description: "Undo overwrote occupied path") }
            catch is TransferEngineError {}
            try require(try String(contentsOf: source, encoding: .utf8) == "replacement", "Undo replaced file")
            passed.append("undo refuses occupied original path")
        }
        do {
            let (src, dst, engine) = try fixture("conflicts")
            let source = try file(src); let old = try file(dst, "file.txt", "existing")
            let skipped = await engine.transfer(sources: [source], to: dst, mode: .copy, conflictPolicy: .skip)
            try require(skipped.items[0].status == .skipped, "Skip not honored")
            let copied = await engine.transfer(sources: [source], to: dst, mode: .copy, conflictPolicy: .keepBoth)
            try require(copied.completedCount == 1, "Keep both failed: \(copied.items)")
            try require(try String(contentsOf: old, encoding: .utf8) == "existing", "Existing content overwritten")
            try require(copied.items[0].destination?.lastPathComponent == "file 2.txt", "Wrong keep-both name")
            passed.append("skip and keep-both preserve existing bytes")
        }
        do {
            let (src, dst, engine) = try fixture("commit-race")
            let source = try file(src)
            await engine.configureTesting(phaseHook: { phase, _, target in
                if phase == "beforeCommit" { try Data("competitor".utf8).write(to: target) }
            })
            let result = await engine.transfer(sources: [source], to: dst, mode: .move, conflictPolicy: .skip)
            try require(result.items[0].status == .skipped, "Commit race was not skipped")
            try require(try String(contentsOf: dst.appendingPathComponent("file.txt"), encoding: .utf8) == "competitor", "Race overwrote competitor")
            try require(fm.fileExists(atPath: source.path), "Race removed source")
            passed.append("atomic no-clobber commit race")
        }
        do {
            let (src, _, engine) = try fixture("descendant")
            let folder = src.appendingPathComponent("folder"), child = folder.appendingPathComponent("child")
            try fm.createDirectory(at: child, withIntermediateDirectories: true)
            let result = await engine.transfer(sources: [folder], to: child, mode: .copy)
            try require(result.items[0].status == .failed, "Accepted descendant target")
            passed.append("directory descendant target rejected")
        }
        do {
            let (src, dst, engine) = try fixture("symlinks")
            let folder = src.appendingPathComponent("package.app")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try file(folder)
            try fm.createSymbolicLink(atPath: folder.appendingPathComponent("loop").path, withDestinationPath: ".")
            try fm.createSymbolicLink(atPath: folder.appendingPathComponent("missing").path, withDestinationPath: "no-such-file")
            let result = await engine.transfer(sources: [folder], to: dst, mode: .copy)
            try require(result.completedCount == 1, "Symlink copy failed: \(result.items)")
            try require(try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("package.app/loop").path) == ".", "Followed loop symlink")
            passed.append("package and cyclic/dangling symlinks copied without following")
        }
        do {
            let (src, dst, engine) = try fixture("special")
            let pipe = src.appendingPathComponent("pipe")
            try require(mkfifo(pipe.path, 0o600) == 0, "FIFO fixture failed")
            let result = await engine.transfer(sources: [pipe, try file(src)], to: dst, mode: .move)
            try require(result.state == "partial" && result.items[0].status == .failed && result.items[1].status == .completed, "Special file failure not isolated")
            passed.append("special files rejected; batch success retained")
        }
        do {
            let (src, dst, engine) = try fixture("cancel-before")
            let source = try file(src), token = TransferCancellation(); token.cancel()
            let result = await engine.transfer(sources: [source], to: dst, mode: .move, cancellation: token)
            try require(result.state == "cancelled" && fm.fileExists(atPath: source.path), "Cancellation removed source")
            passed.append("queued cancellation has no source side effect")
        }
        do {
            let (src, dst, engine) = try fixture("verified-copy-move")
            let folder = src.appendingPathComponent("folder")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = try file(folder)
            let attribute = "user fixture metadata"
            _ = attribute.withCString { setxattr(source.path, "com.rightmouse.fixture", $0, strlen($0), 0, 0) }
            await engine.configureTesting(forceCrossVolume: true)
            let result = await engine.transfer(sources: [folder], to: dst, mode: .move)
            try require(result.completedCount == 1 && !fm.fileExists(atPath: folder.path), "Verified copy-then-cleanup failed: \(result.items)")
            try require(try String(contentsOf: dst.appendingPathComponent("folder/file.txt"), encoding: .utf8) == "original", "Copy-then-cleanup content mismatch")
            passed.append("copy-verify-commit-cleanup path including directory and xattr (injected cross-volume path)")
        }
        do {
            let (src, dst, engine) = try fixture("cancel-after-commit")
            let source = try file(src), token = TransferCancellation()
            await engine.configureTesting(forceCrossVolume: true, phaseHook: { phase, _, _ in if phase == "afterCommit" { token.cancel() } })
            let result = await engine.transfer(sources: [source], to: dst, mode: .move, cancellation: token)
            try require(result.items[0].status == .sourceRetained && fm.fileExists(atPath: source.path), "Post-commit cancellation removed source")
            try require(fm.fileExists(atPath: dst.appendingPathComponent("file.txt").path), "Post-commit cancellation lost target")
            passed.append("post-commit cancellation reports two copies")
        }
        do {
            let (src, dst, engine) = try fixture("source-changed")
            let source = try file(src)
            await engine.configureTesting(forceCrossVolume: true, phaseHook: { phase, original, _ in if phase == "beforeSourceCleanup" { try Data("changed".utf8).write(to: original) } })
            let result = await engine.transfer(sources: [source], to: dst, mode: .move)
            try require(result.items[0].status == .sourceRetained, "Source modification not retained")
            try require(try String(contentsOf: source, encoding: .utf8) == "changed", "Source modification lost")
            let records = try await engine.recoveryRecords()
            try require(records.count == 1 && records[0].phase == "sourceRetained", "Recovery record missing")
            passed.append("source mutation before cleanup retained and journaled")
        }
        do {
            let (src, dst, engine) = try fixture("journal-failure")
            let source = try file(src)
            let badJournal = try file(src, "not-a-directory")
            let badEngine = FileTransferEngine(journalDirectory: badJournal)
            let result = await badEngine.transfer(sources: [source], to: dst, mode: .move)
            try require(result.state == "failed" && fm.fileExists(atPath: source.path), "Journal failure mutated source")
            _ = engine
            passed.append("journal unavailable prevents mutation")
        }
        do {
            let (src, dst, engine) = try fixture("source-replaced-before-commit")
            let source = try file(src)
            await engine.configureTesting(phaseHook: { phase, original, _ in
                if phase == "beforeCommit" { try fm.removeItem(at: original); try Data("replacement".utf8).write(to: original) }
            })
            let result = await engine.transfer(sources: [source], to: dst, mode: .move)
            try require(result.items[0].status == .failed, "Replaced source moved")
            try require(try String(contentsOf: source, encoding: .utf8) == "replacement", "Replacement lost")
            passed.append("source replacement at commit refused")
        }
        do {
            let (src, dst, engine) = try fixture("target-changed-before-cleanup")
            let source = try file(src)
            await engine.configureTesting(forceCrossVolume: true, phaseHook: { phase, _, target in
                if phase == "beforeSourceCleanup" { try Data("changed-target".utf8).write(to: target) }
            })
            let result = await engine.transfer(sources: [source], to: dst, mode: .move)
            try require(result.items[0].status == .sourceRetained, "Changed target allowed source cleanup")
            try require(try String(contentsOf: source, encoding: .utf8) == "original", "Original lost")
            passed.append("target mutation prevents source cleanup")
        }
        do {
            let (src, dst, engine) = try fixture("undo-nested-change")
            let folder = src.appendingPathComponent("folder")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try file(folder)
            let result = await engine.transfer(sources: [folder], to: dst, mode: .move)
            try Data("modified".utf8).write(to: dst.appendingPathComponent("folder/file.txt"))
            do { try await engine.undo(result.items[0].undoToken!); throw Failed(description: "Undo accepted changed descendant") }
            catch is TransferEngineError {}
            passed.append("undo validates nested contents")
        }
        do {
            let (src, dst, engine) = try fixture("stream-cancel")
            let source = src.appendingPathComponent("large.bin")
            try Data(repeating: 42, count: 4 * 1024 * 1024).write(to: source)
            let token = TransferCancellation()
            let result = await engine.transfer(sources: [source], to: dst, mode: .copy, cancellation: token, onProgress: { progress in
                if progress.phase == "copying" && progress.bytesProcessed >= 1024 * 1024 { token.cancel() }
            })
            try require(result.items[0].status == .cancelled, "Stream cancellation failed")
            try require(try fm.contentsOfDirectory(atPath: dst.path).isEmpty, "Cancelled copy left staging file")
            try require(try Data(contentsOf: source).count == 4 * 1024 * 1024, "Cancelled copy changed source")
            passed.append("stream cancellation cleans private staging and keeps source")
        }
        return passed
    }
}
