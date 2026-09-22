import Foundation
import Darwin
@testable import RightMouseCore

private struct StagingRetentionFailure: Error, CustomStringConvertible { let description: String }

func runStagingRetentionChecks() async throws -> Int {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("rightmouse-staging-retention-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw StagingRetentionFailure(description: title) }
        count += 1; print("PASS staging retention: \(title)")
    }
    for scenario in ["success", "failure", "replacement"] {
        let base = root.appendingPathComponent(scenario)
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("item.txt")
        try Data("original-content".utf8).write(to: source)
        let engine = FileTransferEngine(journalDirectory: base.appendingPathComponent("journal"))
        if scenario != "success" {
            await engine.configureTesting(phaseHook: { phase, _, destination in
                guard phase == "beforeCopy" else { return }
                if scenario == "replacement" {
                    let parent = destination.deletingLastPathComponent()
                    let staging = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".rightmouse-") }!
                    try FileManager.default.moveItem(at: staging, to: parent.appendingPathComponent("original-staging"))
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                    try Data("replacement-sentinel".utf8).write(to: staging.appendingPathComponent("keep.txt"))
                }
                throw TransferEngineError.system(ENOSPC)
            })
        }
        let result = await engine.transfer(sources: [source], to: target, mode: .copy)
        let scan = try await engine.scanRecoveryRecords()
        guard let journal = scan.records.first else { throw StagingRetentionFailure(description: "missing journal") }
        if scenario == "replacement" {
            try check(result.items.first?.status == .failed && journal.stagingURL != nil, "unverified staging cleanup retains its journal reference")
            try check(try Data(contentsOf: journal.stagingURL!.appendingPathComponent("keep.txt")) == Data("replacement-sentinel".utf8), "changed staging inode is never recursively removed")
        } else {
            try check(journal.stagingURL == nil, "\(scenario) records clear staging reference only after verified cleanup")
            try check(try FileManager.default.contentsOfDirectory(atPath: target.path).allSatisfy { !$0.hasPrefix(".rightmouse-") }, "\(scenario) actually removes the private staging container")
        }
        try check(try Data(contentsOf: source) == Data("original-content".utf8), "\(scenario) cleanup preserves source bytes")
    }
    return count
}
