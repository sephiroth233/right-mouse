import Foundation
import Darwin
@testable import RightMouseCore

private struct TransferFailureCheckError: Error, CustomStringConvertible {
    let description: String
}

func runTransferFailureChecks() async throws -> Int {
    let fm = FileManager.default
    let requestedRoot = fm.temporaryDirectory.appendingPathComponent("rightmouse-transfer-failures-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: requestedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
    defer { try? fm.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw TransferFailureCheckError(description: name) }
        count += 1
        print("PASS transfer-failure: \(name)")
    }
    func fixture(_ name: String) throws -> (sourceDirectory: URL, target: URL, engine: FileTransferEngine) {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (source, target, FileTransferEngine(journalDirectory: base.appendingPathComponent("journal", isDirectory: true)))
    }
    func file(_ directory: URL, name: String = "item.txt") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    do {
        let (_, target, engine) = try fixture("missing")
        let missing = root.appendingPathComponent("missing.txt")
        let result = await engine.transfer(sources: [missing], to: target, mode: .copy)
        try check(result.items[0].status == .failed, "missing source remains a failed item")
        try check(result.items[0].failure?.code == .sourceMissing, "missing source has SOURCE_MISSING code")
        try check(result.items[0].failure?.retryable == false, "missing source is not presented as an automatic retry")
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("permission")
        let source = try file(sourceDirectory)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }
        let result = await engine.transfer(sources: [source], to: target, mode: .copy)
        try check(result.items[0].failure?.code == .accessDenied, "real unwritable destination has ACCESS_DENIED code")
        try check(fm.fileExists(atPath: source.path), "permission failure preserves the source")
    }

    for (name, code, expected) in [("no-space", ENOSPC, CommandErrorCode.noSpace), ("detached-volume", ENODEV, .volumeUnavailable)] {
        let (sourceDirectory, target, engine) = try fixture(name)
        let source = try file(sourceDirectory)
        await engine.configureTesting(phaseHook: { phase, _, _ in
            if phase == "beforeCopy" { throw TransferEngineError.system(code) }
        })
        let result = await engine.transfer(sources: [source], to: target, mode: .copy)
        try check(result.items[0].failure?.code == expected, "injected \(name) receives its protocol code")
        try check(result.items[0].failure?.retryable == true, "injected \(name) is retryable")
        try check(fm.fileExists(atPath: source.path), "injected \(name) preserves source")
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("source-change")
        let source = try file(sourceDirectory)
        await engine.configureTesting(phaseHook: { phase, _, _ in
            if phase == "beforeCommit" { throw TransferEngineError.sourceChanged }
        })
        let result = await engine.transfer(sources: [source], to: target, mode: .copy)
        try check(result.items[0].failure?.code == .sourceChanged, "source mutation has SOURCE_CHANGED code")
        try check(result.items[0].destination == nil && fm.fileExists(atPath: source.path), "pre-commit source mutation exposes no committed destination")
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("conflict-cancel")
        let source = try file(sourceDirectory)
        _ = try file(target)
        let result = await engine.transfer(sources: [source], to: target, mode: .copy, conflictPolicy: .ask,
                                           resolveConflict: { _, _ in .cancel })
        try check(result.items[0].status == .cancelled && result.items[0].failure?.code == .cancelled, "conflict cancellation has CANCELLED code")
        try check(try Data(contentsOf: target.appendingPathComponent("item.txt")) == Data("fixture".utf8), "conflict cancellation does not overwrite target")
    }

    do {
        let retained = TransferFailureMapping.conservativeFailure(for: TransferEngineError.cancelled, status: .sourceRetained, committed: true)
        try check(retained.code == .sourceRetained && !retained.retryable, "post-commit source retention conservatively maps to SOURCE_RETAINED")
        let uncertain = TransferFailureMapping.conservativeFailure(for: TransferEngineError.system(EIO), status: .needsReview, committed: true)
        try check(uncertain.code == .recoveryRequired && !uncertain.retryable, "uncertain committed result requires review instead of blind retry")
    }

    do {
        let source = URL(fileURLWithPath: "/fixture/old.txt")
        let oldObject: [String: Any] = [
            "itemID": UUID().uuidString,
            "operationID": UUID().uuidString,
            "source": source.absoluteString,
            "status": "failed",
            "message": "旧记录"
        ]
        let data = try JSONSerialization.data(withJSONObject: oldObject)
        let decoded = try JSONDecoder().decode(TransferItemResult.self, from: data)
        try check(decoded.failure == nil && decoded.message == "旧记录", "legacy result without failure decodes compatibly")
    }

    let occupied = TransferFailureMapping.failure(for: TransferEngineError.occupied)
    try check(occupied.code == .destinationConflict && occupied.retryable, "occupied target maps to retryable DESTINATION_CONFLICT")
    let unknown = TransferFailureMapping.failure(for: NSError(domain: "fixture.unknown", code: 77))
    try check(unknown.code == .ioFailed && !unknown.retryable, "unknown errors remain non-retryable generic IO_FAILED")
    let vanishedTarget = TransferFailureMapping.failure(for: TransferEngineError.system(ENOENT), context: .destination)
    try check(vanishedTarget.code == .invalidDestination, "missing target is not mislabeled as a missing source")

    return count
}
