import Foundation
import Darwin
@testable import RightMouseCore

func runRaceChecks() async throws -> Int {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("rightmouse-race-checks-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var passed = 0
    func fixture(_ name: String) throws -> (URL, URL, FileTransferEngine) {
        let base = root.appendingPathComponent(name)
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        return (source, target, FileTransferEngine(journalDirectory: base.appendingPathComponent("journal")))
    }
    func write(_ directory: URL, _ text: String = "original") throws -> URL {
        let url = directory.appendingPathComponent("item.txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("copy-commit-replacement")
        let source = try write(sourceDirectory)
        await engine.configureTesting(phaseHook: { phase, _, destination in
            if phase == "immediatelyAfterSourceRename" {
                try fm.removeItem(at: destination)
                try Data("replacement-copy".utf8).write(to: destination)
            }
        })
        let result = await engine.transfer(sources: [source], to: target, mode: .copy)
        try require(result.items[0].status == .needsReview, "copy target replacement was reported as completed")
        try require(try String(contentsOf: source, encoding: .utf8) == "original", "copy source changed")
        try require(try String(contentsOf: target.appendingPathComponent("item.txt"), encoding: .utf8) == "replacement-copy", "copy replacement was deleted")
        print("PASS race: copy post-commit replacement requires review and preserves both objects")
        passed += 1
    }

    do {
        let (preSourceDirectory, preTarget, preEngine) = try fixture("same-volume-pre-rename-replacement")
        let preSource = try write(preSourceDirectory)
        let preBackup = preSourceDirectory.appendingPathComponent("selected-object.backup")
        await preEngine.configureTesting(phaseHook: { phase, original, _ in
            if phase == "immediatelyBeforeSourceRename" {
                try fm.moveItem(at: original, to: preBackup)
                try Data("replacement-before-rename".utf8).write(to: original)
            }
        })
        let preResult = await preEngine.transfer(sources: [preSource], to: preTarget, mode: .move)
        try require(preResult.items[0].status != .completed, "pre-rename replacement was reported as completed")
        let preDelivered = preTarget.appendingPathComponent("item.txt")
        let retainedURL = fm.fileExists(atPath: preSource.path) ? preSource : preDelivered
        try require(try String(contentsOf: retainedURL, encoding: .utf8) == "replacement-before-rename", "pre-rename replacement was not retained")
        try require(try String(contentsOf: preBackup, encoding: .utf8) == "original", "selected object backup was lost")

        let (sourceDirectory, target, engine) = try fixture("same-volume-replacement")
        let source = try write(sourceDirectory)
        await engine.configureTesting(phaseHook: { phase, _, destination in
            if phase == "immediatelyAfterSourceRename" {
                try fm.removeItem(at: destination)
                try Data("replacement".utf8).write(to: destination)
            }
        })
        let result = await engine.transfer(sources: [source], to: target, mode: .move)
        let delivered = target.appendingPathComponent("item.txt")
        try require(result.items[0].status == .needsReview, "same-volume replacement status was \(result.items[0].status): \(result.items[0].message); source=\(fm.fileExists(atPath: source.path)) destination=\(fm.fileExists(atPath: delivered.path))")
        try require(try String(contentsOf: delivered, encoding: .utf8) == "replacement", "replacement object was lost")
        print("PASS race: same-volume adjacent pre/post-rename replacement is retained and never reported completed")
        passed += 1
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("cleanup-replacement")
        let source = try write(sourceDirectory)
        let selectedBackup = sourceDirectory.appendingPathComponent("selected-object.backup")
        await engine.configureTesting(forceCrossVolume: true, phaseHook: { phase, original, _ in
            if phase == "immediatelyBeforeSourceIsolationRename" {
                try fm.moveItem(at: original, to: selectedBackup)
                try Data("replacement".utf8).write(to: original)
            }
        })
        let result = await engine.transfer(sources: [source], to: target, mode: .move)
        try require(result.items[0].status == .needsReview, "isolated replacement was reported as success")
        let record = try await engine.recoveryRecords().first!
        let isolated = try record.sourceCleanupURL.unwrap(or: Failure(description: "missing cleanup evidence"))
        try require(try String(contentsOf: isolated, encoding: .utf8) == "replacement", "isolated replacement was deleted")
        try require(try String(contentsOf: selectedBackup, encoding: .utf8) == "original", "selected source object was lost")
        try require(record.sourceCleanupState == .needsReview, "cleanup review state was not persisted")
        print("PASS race: cleanup quarantine preserves a replacement for review")
        passed += 1
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("new-original-after-isolation")
        let source = try write(sourceDirectory)
        await engine.configureTesting(forceCrossVolume: true, phaseHook: { phase, original, _ in
            if phase == "afterSourceIsolation" { try Data("new-at-original".utf8).write(to: original) }
        })
        let result = await engine.transfer(sources: [source], to: target, mode: .move)
        try require(result.items[0].status == .completed, "verified isolated source did not complete")
        try require(try String(contentsOf: source, encoding: .utf8) == "new-at-original", "new object at the old path was touched")
        try require(try String(contentsOf: target.appendingPathComponent("item.txt"), encoding: .utf8) == "original", "committed target changed")
        let record = try await engine.recoveryRecords().first!
        try require(record.sourceCleanupState == .completed && record.sourceCleanupURL == nil, "successful cleanup evidence was not closed")
        print("PASS race: post-isolation object at original path is untouched")
        passed += 1
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("undo-replacement")
        let source = try write(sourceDirectory)
        let moved = await engine.transfer(sources: [source], to: target, mode: .move)
        let token = try moved.items[0].undoToken.unwrap(or: Failure(description: "missing undo token"))
        let selectedBackup = target.appendingPathComponent("selected-object.backup")
        await engine.configureTesting(phaseHook: { phase, current, _ in
            if phase == "immediatelyBeforeUndoRename" {
                try fm.moveItem(at: current, to: selectedBackup)
                try Data("replacement".utf8).write(to: current)
            }
        })
        do {
            try await engine.undo(token)
            throw Failure(description: "undo replacement was reported as completed")
        } catch TransferEngineError.unsafeUndo {}
        try require(try String(contentsOf: source, encoding: .utf8) == "replacement", "undo replacement was lost")
        try require(try String(contentsOf: selectedBackup, encoding: .utf8) == "original", "undo selected object was lost")
        let records = try await engine.recoveryRecords()
        try require(records.contains(where: { $0.phase == "undoCommitting" && $0.result == nil }), "uncertain undo was not left for review")
        print("PASS race: undo post-rename validation detects replacement")
        passed += 1
    }

    do {
        let (sourceDirectory, target, engine) = try fixture("hardlinks")
        let first = try write(sourceDirectory, "hardlink-content")
        let second = sourceDirectory.appendingPathComponent("second.txt")
        guard link(first.path, second.path) == 0 else { throw Failure(description: "hardlink fixture failed") }
        let result = await engine.transfer(sources: [sourceDirectory], to: target, mode: .copy)
        let copied = target.appendingPathComponent("source")
        try require(result.items[0].status == .completed, "hardlink content copy failed")
        try require(try String(contentsOf: copied.appendingPathComponent("item.txt"), encoding: .utf8) == "hardlink-content", "first hardlink bytes changed")
        try require(try String(contentsOf: copied.appendingPathComponent("second.txt"), encoding: .utf8) == "hardlink-content", "second hardlink bytes changed")
        let moveTarget = root.appendingPathComponent("hardlinks-move-target")
        try fm.createDirectory(at: moveTarget, withIntermediateDirectories: true)
        await engine.configureTesting(forceCrossVolume: true)
        let moved = await engine.transfer(sources: [sourceDirectory], to: moveTarget, mode: .move)
        try require(moved.items[0].status == .completed && !fm.fileExists(atPath: sourceDirectory.path), "hardlink cross-volume cleanup failed: \(moved.items[0].status)")
        try require(try String(contentsOf: moveTarget.appendingPathComponent("source/item.txt"), encoding: .utf8) == "hardlink-content", "moved hardlink bytes changed")
        print("PASS race: hardlinks retain bytes without requiring topology preservation")
        passed += 1
    }
    return passed
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
