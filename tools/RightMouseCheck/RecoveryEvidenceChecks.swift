import Foundation
import Darwin
import RightMouseCore

private struct EvidenceCheckFailure: Error, CustomStringConvertible { let description: String }

func runRecoveryEvidenceChecks() throws -> Int {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-evidence-" + UUID().uuidString)
    let paths = SharedPaths(root: root)
    try paths.prepare()
    defer { try? FileManager.default.removeItem(at: root) }
    let privateRoot = paths.operationsDirectory.deletingLastPathComponent()
    let backups = privateRoot.appendingPathComponent("Backups")
    let store = RecoveryEvidenceStore(paths: paths, backupRoot: backups)
    let id = UUID(), commands = paths.operationsDirectory.appendingPathComponent("Commands")
    let source = commands.appendingPathComponent(id.uuidString + ".json")
    let original = Data([0xff, 0, 1, 2, 0x7b])
    try PrivateFileIO.write(original, to: source)
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw EvidenceCheckFailure(description: name) }
        count += 1; print("PASS evidence: \(name)")
    }
    func members(_ directory: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") } }
    func preserve(_ category: RecoveryEvidenceCategory = .commands) -> RecoveryEvidenceResult { store.preserve(sourceURL: source, category: category, recordID: id, now: Date(timeIntervalSince1970: 123456)) }
    let created = preserve()
    try check(created.status == .created && created.byteCount == original.count, "corrupt undecodable source is preserved as original bytes")
    let firstFiles = try members(backups)
    let byteFile = firstFiles.first { $0.pathExtension == "bytes" }!, metadataFile = firstFiles.first { $0.pathExtension == "json" }!
    try check(try Data(contentsOf: byteFile) == original && Data(contentsOf: source) == original, "byte roundtrip leaves original untouched")
    let metadataBytes = try Data(contentsOf: metadataFile)
    let metadata = try WireCodec.decoder().decode(RecoveryEvidenceMetadata.self, from: metadataBytes)
    try check(metadata.schemaVersion == 1 && metadata.recordID == id && metadata.category == .commands && metadata.byteCount == original.count && metadata.preservedAt == Date(timeIntervalSince1970: 123456), "metadata contains only typed identity digest size and preservation time")
    let metadataObject = try JSONSerialization.jsonObject(with: metadataBytes) as! [String: Any]
    try check(Set(metadataObject.keys) == Set(["schemaVersion", "category", "recordID", "contentSHA256", "byteCount", "preservedAt"]), "metadata contains no source path or embedded business fields")
    try check(preserve().status == .alreadyPreserved && (try members(backups).count) == 2 && (try Data(contentsOf: metadataFile)) == metadataBytes, "repeated scans deduplicate without modifying first preservation time")
    for url in [byteFile, metadataFile] {
        var info = stat(); lstat(url.path, &info)
        try check(info.st_mode & 0o777 == 0o600, "preserved record file has mode 0600")
    }
    var directoryInfo = stat(); lstat(backups.path, &directoryInfo)
    try check(directoryInfo.st_mode & 0o777 == 0o700, "backup directory has mode 0700")
    let future = Data("{\"schemaVersion\":999,\"private\":\"future payload\"}".utf8)
    try PrivateFileIO.write(future, to: source)
    try check(preserve().status == .created && (try members(backups).count) == 4, "changed future-schema bytes create one additional evidence pair without decoding")
    try check(try Data(contentsOf: byteFile) == original && Data(contentsOf: source) == future, "new content never overwrites old evidence or source")
    try check(preserve().status == .alreadyPreserved && (try members(backups).count) == 4, "future-version scans also deduplicate")
    let transferSource = paths.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(id.uuidString + ".json")
    try PrivateFileIO.write(future, to: transferSource)
    try check(store.preserve(sourceURL: transferSource, category: .transfers, recordID: id).status == .created && (try members(backups).count) == 6, "identical bytes and UUID in another allowed category have separate evidence")
    try check(preserve(.transfers).failureCode == .invalidLocation, "category cannot remap a source path")
    try check(store.preserve(sourceURL: source, category: .commands, recordID: UUID()).failureCode == .invalidLocation, "record ID must match the fixed source filename")
    let outside = root.appendingPathComponent("outside.json"); try PrivateFileIO.write(future, to: outside)
    try check(store.preserve(sourceURL: outside, category: .commands, recordID: id).failureCode == .invalidLocation, "arbitrary source outside fixed Operations category is refused")
    let escape = RecoveryEvidenceStore(paths: paths, backupRoot: privateRoot.appendingPathComponent("other-backups"))
    try check(escape.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .invalidLocation, "backup root must be under private Backups namespace")
    let small = RecoveryEvidenceStore(paths: paths, backupRoot: backups.appendingPathComponent("small"), limits: .init(maximumFileBytes: 4))
    try check(small.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .oversized && (try Data(contentsOf: source)) == future, "single-file limit refuses bytes without changing source")
    let full = RecoveryEvidenceStore(paths: paths, backupRoot: backups.appendingPathComponent("full"), limits: .init(maximumTotalBytes: 32))
    try check(full.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .capacityExceeded && (try Data(contentsOf: source)) == future, "capacity limit preserves source and never recycles unreviewed evidence")
    let oneRoot = backups.appendingPathComponent("one")
    let one = RecoveryEvidenceStore(paths: paths, backupRoot: oneRoot, limits: .init(maximumRecords: 1))
    try check(one.preserve(sourceURL: source, category: .commands, recordID: id).status == .created, "record-count fixture admits its first evidence")
    try PrivateFileIO.write(Data("another version".utf8), to: source)
    try check(one.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .capacityExceeded && (try members(oneRoot).count) == 2, "record-count limit blocks extra versions without deleting the first")
    try PrivateFileIO.write(future, to: source)
    let boundedRoot = backups.appendingPathComponent("bounded")
    let bounded = RecoveryEvidenceStore(paths: paths, backupRoot: boundedRoot, limits: .init(maximumTotalBytes: 512))
    try check(bounded.preserve(sourceURL: source, category: .commands, recordID: id).status == .created, "total-capacity fixture admits its first complete pair")
    try PrivateFileIO.write(Data(repeating: 65, count: 100), to: source)
    try check(bounded.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .capacityExceeded && (try members(boundedRoot).count) == 2, "occupied total capacity refuses another version and retains the first pair")
    try PrivateFileIO.write(Data(repeating: 66, count: 8 * 1024 * 1024 + 1), to: source)
    let oversized = RecoveryEvidenceStore(paths: paths, backupRoot: backups.appendingPathComponent("oversized"), limits: .init(maximumFileBytes: 16 * 1024 * 1024))
    try check(oversized.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .oversized && (try Data(contentsOf: source).count) == 8 * 1024 * 1024 + 1, "8 MiB hard ceiling cannot be raised by configured limits")
    try PrivateFileIO.write(future, to: source)
    let boundedBytes = try members(boundedRoot).first { $0.pathExtension == "bytes" }!
    let extraLink = root.appendingPathComponent("backup-hardlink")
    try FileManager.default.linkItem(at: boundedBytes, to: extraLink)
    try check(bounded.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .unsafeFile && (try Data(contentsOf: extraLink)) == future, "existing backup hardlink is refused without changing evidence")
    try FileManager.default.removeItem(at: extraLink)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: boundedRoot.path)
    try check(bounded.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .unsafeFile, "non-private backup directory is refused")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: boundedRoot.path)
    // Source symlink and hardlink tests leave both original targets intact.
    try FileManager.default.removeItem(at: source); try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
    try check(preserve().failureCode == .unsafeFile && (try Data(contentsOf: outside)) == future, "source symlink is refused without touching target")
    try FileManager.default.removeItem(at: source); try FileManager.default.linkItem(at: outside, to: source)
    try check(preserve().failureCode == .unsafeFile && (try Data(contentsOf: outside)) == future, "source hardlink is refused")
    try FileManager.default.removeItem(at: source); try PrivateFileIO.write(future, to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
    try check(preserve().failureCode == .unsafeFile, "group-readable source is refused")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    let sourceParent = paths.operationsDirectory.appendingPathComponent("Followups")
    let externalDirectory = root.appendingPathComponent("external"); try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try PrivateFileIO.write(future, to: externalDirectory.appendingPathComponent(id.uuidString + ".json"))
    try FileManager.default.createSymbolicLink(at: sourceParent, withDestinationURL: externalDirectory)
    try check(store.preserve(sourceURL: sourceParent.appendingPathComponent(id.uuidString + ".json"), category: .followups, recordID: id).failureCode == .unsafeFile, "symlink source parent cannot escape category directory")
    let linkedBackup = backups.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linkedBackup, withDestinationURL: externalDirectory)
    let linked = RecoveryEvidenceStore(paths: paths, backupRoot: linkedBackup)
    try check(linked.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .unsafeFile, "backup parent symlink cannot redirect recovery bytes")
    // A pre-existing member is never overwritten, even if it has been corrupted.
    let oneBytes = try members(oneRoot).first { $0.pathExtension == "bytes" }!
    try PrivateFileIO.write(Data("tampered".utf8), to: oneBytes)
    try check(one.preserve(sourceURL: source, category: .commands, recordID: id).failureCode == .backupConflict && (try Data(contentsOf: oneBytes)) == Data("tampered".utf8), "existing conflicting evidence is reported and never overwritten")
    try check(try Data(contentsOf: source) == future && Data(contentsOf: byteFile) == original, "all refusal paths leave source and earlier valid evidence unchanged")
    return count
}
