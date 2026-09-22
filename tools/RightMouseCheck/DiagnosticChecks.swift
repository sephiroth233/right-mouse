import Foundation
import Darwin
import RightMouseCore

private struct DiagnosticCheckFailure: Error, CustomStringConvertible { let description: String }

func runDiagnosticChecks() throws -> Int {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("rightmouse-diagnostics-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw DiagnosticCheckFailure(description: title) }
        count += 1
    }
    func records(_ export: DiagnosticLogExport) throws -> [[String: Any]] {
        try String(decoding: export.data, as: UTF8.self).split(separator: "\n").map {
            guard let object = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else { throw DiagnosticCheckFailure(description: "export is not readable JSONL") }
            return object
        }
    }
    let initial = Date(timeIntervalSince1970: 1_750_000_000)
    var now = initial
    let directory = root.appendingPathComponent("legal")
    let store = DiagnosticLogStore(directory: directory, clock: { now })
    let requestID = UUID()
    let appended = store.append(component: .host, event: .requestFinished, requestID: requestID, action: .copyTo, status: .failed, errorCode: .accessDenied)
    try check(appended.persisted && appended.retainedRecords == 1 && appended.issues.total == 0, "typed event did not persist")
    let exported = store.export()
    let event = try records(exported)[0]
    try check(event["requestID"] as? String == requestID.uuidString && event["action"] as? String == "copyTo" && event["status"] as? String == "failed" && event["errorCode"] as? String == "ACCESS_DENIED", "typed event roundtrip lost safe fields")
    try check(Set(event.keys) == ["schemaVersion", "timestamp", "component", "event", "requestID", "action", "status", "errorCode"], "export schema exposes non-whitelisted fields")
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DiagnosticRecord.self, from: Data(String(decoding: exported.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    try check(decoded.requestID == requestID && decoded.timestamp == initial, "public typed diagnostic record does not roundtrip")
    let directoryMode = (try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber).intValue
    let fileMode = (try fm.attributesOfItem(atPath: directory.appendingPathComponent(DiagnosticLogStore.fileName).path)[.posixPermissions] as! NSNumber).intValue
    try check(directoryMode == 0o700 && fileMode == 0o600, "diagnostic directory/file permissions are not private")
    now = initial.addingTimeInterval(7 * 24 * 60 * 60 - 1)
    try check(store.export().report.retainedRecords == 1, "seven-day retention expired an event early")
    now = initial.addingTimeInterval(7 * 24 * 60 * 60)
    let expired = store.export()
    try check(expired.data.isEmpty && expired.report.issues.expiredRecords == 1 && expired.report.persisted, "seven-day exact boundary did not rotate expired record")
    try check(try Data(contentsOf: directory.appendingPathComponent(DiagnosticLogStore.fileName)).isEmpty, "expired bytes remain in active log")

    let bytesPerEvent = exported.data.count
    let quotaDir = root.appendingPathComponent("quota")
    let quota = DiagnosticLogStore(directory: quotaDir, limits: .init(maximumBytes: bytesPerEvent * 2), clock: { now })
    var ids: [UUID] = []
    var capacityDrops = 0
    for _ in 0..<5 {
        let id = UUID(); ids.append(id)
        let report = quota.append(component: .host, event: .requestFinished, requestID: id, action: .copyTo, status: .failed, errorCode: .accessDenied)
        capacityDrops += report.issues.capacityDroppedRecords
        try check(report.persisted && report.retainedBytes <= bytesPerEvent * 2, "capacity exceeded configured byte quota")
    }
    let retainedIDs = try records(quota.export()).compactMap { $0["requestID"] as? String }
    try check(retainedIDs == ids.suffix(2).map(\.uuidString) && capacityDrops == 3, "quota did not discard oldest events first")
    let zero = DiagnosticLogStore(directory: root.appendingPathComponent("zero"), limits: .init(maximumBytes: 0), clock: { now })
    let zeroReport = zero.append(component: .host, event: .hostStarted)
    try check(zeroReport.persisted && zeroReport.retainedBytes == 0 && zeroReport.issues.capacityDroppedRecords == 1, "undersized quota is not bounded")
    try check(DiagnosticLogLimits(retentionSeconds: .infinity, maximumBytes: Int.max).maximumBytes == 10 * 1024 * 1024 && DiagnosticLogLimits(retentionSeconds: .infinity).retentionSeconds == 7 * 24 * 60 * 60, "production retention and capacity maxima can be expanded by injection")

    let noRetention = DiagnosticLogStore(directory: root.appendingPathComponent("zero-retention"), limits: .init(retentionSeconds: 0), clock: { now })
    let noRetentionReport = noRetention.append(component: .host, event: .hostStarted)
    try check(noRetentionReport.persisted && noRetentionReport.retainedRecords == 0 && noRetentionReport.issues.expiredRecords == 1, "zero retention keeps a new record past its expiry")

    let contaminatedDir = root.appendingPathComponent("contaminated")
    try fm.createDirectory(at: contaminatedDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var safe = event
    safe["timestamp"] = ISO8601DateFormatter().string(from: now)
    let secret = "SECRET_CONTENT_/Users/person/private.txt_BOOKMARK_BYTES"
    var injected = safe; injected["path"] = secret; injected["message"] = secret; injected["bookmark"] = secret; injected["nested"] = ["body": secret]
    var futureSchema = safe; futureSchema["schemaVersion"] = 999; futureSchema["path"] = secret
    var futureTime = safe; futureTime["timestamp"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(1)); futureTime["message"] = secret
    var unknownEvent = safe; unknownEvent["event"] = secret
    var invalidRequestID = safe; invalidRequestID["requestID"] = secret
    var contaminated = Data()
    for object in [safe, injected, futureSchema, futureTime, unknownEvent, invalidRequestID] {
        contaminated.append(try JSONSerialization.data(withJSONObject: object)); contaminated.append(0x0A)
    }
    contaminated.append(Data("{malformed_\(secret)\n".utf8))
    contaminated.append(Data(repeating: 0x41, count: 2049)); contaminated.append(0x0A)
    let contaminatedURL = contaminatedDir.appendingPathComponent(DiagnosticLogStore.fileName)
    try PrivateFileIO.write(contaminated, to: contaminatedURL)
    let filtered = DiagnosticLogStore(directory: contaminatedDir, clock: { now }).export()
    try check(filtered.report.persisted && filtered.report.retainedRecords == 2, "valid safe records were not retained during sanitization")
    try check(filtered.report.issues.sanitizedRecords == 1 && filtered.report.issues.unsupportedRecords == 1 && filtered.report.issues.futureRecords == 1 && filtered.report.issues.invalidRecords == 4, "corrupt and future log issue counts are incorrect")
    try check(!String(decoding: filtered.data, as: UTF8.self).contains(secret) && !String(decoding: filtered.data, as: UTF8.self).contains("bookmark"), "export leaked raw injected fields")
    try check(try Data(contentsOf: contaminatedURL) == filtered.data, "rotation retained raw contaminated bytes")
    try check(try records(filtered).allSatisfy { Set($0.keys).isSubset(of: Set(event.keys)) }, "sanitized export contains unknown fields")

    let protected = root.appendingPathComponent("protected.json")
    let protectedBytes = Data(secret.utf8)
    try PrivateFileIO.write(protectedBytes, to: protected)
    let linkDir = root.appendingPathComponent("file-link")
    try fm.createDirectory(at: linkDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try fm.createSymbolicLink(at: linkDir.appendingPathComponent(DiagnosticLogStore.fileName), withDestinationURL: protected)
    let linkedStore = DiagnosticLogStore(directory: linkDir, clock: { now })
    try check(!linkedStore.append(component: .host, event: .hostStarted).persisted, "log symlink was accepted for append")
    let linkedExport = linkedStore.export()
    try check(linkedExport.data.isEmpty && linkedExport.report.issues.ioFailures == 1, "log symlink was read during export")
    try check(try Data(contentsOf: protected) == protectedBytes, "log symlink target changed")
    let lockDir = root.appendingPathComponent("lock-link")
    try fm.createDirectory(at: lockDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try fm.createSymbolicLink(at: lockDir.appendingPathComponent(".writer.lock"), withDestinationURL: protected)
    try check(DiagnosticLogStore(directory: lockDir).export().report.issues.ioFailures == 1 && (try Data(contentsOf: protected)) == protectedBytes, "writer-lock symlink was followed")
    let hardLinkDir = root.appendingPathComponent("hard-link")
    try fm.createDirectory(at: hardLinkDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try fm.linkItem(at: protected, to: hardLinkDir.appendingPathComponent(DiagnosticLogStore.fileName))
    try check(DiagnosticLogStore(directory: hardLinkDir).export().data.isEmpty && (try Data(contentsOf: protected)) == protectedBytes, "hard-linked file leaked protected bytes")
    let parentAlias = root.appendingPathComponent("directory-link")
    try fm.createSymbolicLink(at: parentAlias, withDestinationURL: directory)
    let linkedDirectory = DiagnosticLogStore(directory: parentAlias)
    try check(linkedDirectory.export().report.issues.ioFailures == 1, "directory symlink was followed")
    let ancestorAlias = root.appendingPathComponent("ancestor-link")
    try fm.createSymbolicLink(at: ancestorAlias, withDestinationURL: root)
    try check(DiagnosticLogStore(directory: ancestorAlias.appendingPathComponent("legal")).export().report.issues.ioFailures == 1, "ancestor symlink was followed")
    let badModeDir = root.appendingPathComponent("public")
    try fm.createDirectory(at: badModeDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    try check(DiagnosticLogStore(directory: badModeDir).export().report.issues.ioFailures == 1, "public log directory was accepted")

    let oversizedDir = root.appendingPathComponent("oversized")
    try fm.createDirectory(at: oversizedDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try PrivateFileIO.write(Data(repeating: 0x42, count: 10 * 1024 * 1024 + 1), to: oversizedDir.appendingPathComponent(DiagnosticLogStore.fileName))
    let oversizedExport = DiagnosticLogStore(directory: oversizedDir).export()
    try check(oversizedExport.data.isEmpty && oversizedExport.report.issues.oversizedFiles == 1 && oversizedExport.report.persisted, "oversized untrusted log was not bounded and safely rotated")

    let pendingDir = root.appendingPathComponent("pending")
    try fm.createDirectory(at: pendingDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try PrivateFileIO.write(Data(secret.utf8), to: pendingDir.appendingPathComponent(".events.pending"))
    let pendingStore = DiagnosticLogStore(directory: pendingDir, clock: { initial })
    try check(pendingStore.append(component: .host, event: .hostStarted).persisted && !fm.fileExists(atPath: pendingDir.appendingPathComponent(".events.pending").path), "a crash staging file blocks logging or accumulates leftovers")
    try check(!String(decoding: pendingStore.export().data, as: UTF8.self).contains(secret), "stale staging content leaked into export")

    let concurrent = DiagnosticLogStore(directory: root.appendingPathComponent("concurrent"), clock: { initial })
    DispatchQueue.concurrentPerform(iterations: 32) { _ in concurrent.append(component: .host, event: .requestAccepted, requestID: UUID(), status: .accepted) }
    let concurrentExport = concurrent.export()
    try check(concurrentExport.report.retainedRecords == 32 && concurrentExport.report.issues.total == 0, "serialized concurrent appends lost or corrupted records")
    try check(try Set(records(concurrentExport).compactMap { $0["requestID"] as? String }).count == 32, "concurrent diagnostic record IDs were duplicated")
    return count
}
