import Foundation
import Darwin

public enum DiagnosticComponent: String, Codable, Sendable {
    case host, finderExtension, configuration, fileOperations, diagnostics
}
public enum DiagnosticEvent: String, Codable, Sendable {
    case hostStarted, requestAccepted, requestFinished, requestRejected, recoveryDetected
    case configurationLoaded, configurationSaved, exportCompleted, retryRequested, undoRequested, reviewConfirmed, storageUnavailable
}
public enum DiagnosticAction: String, Codable, Sendable {
    case createFile, copyText, stageMove, pasteMove, copyTo, moveTo, openWith, openFavorite, undo, retry
}

/// No message, URL, path, bookmark, file name or content field is accepted by this API.
public struct DiagnosticRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let component: DiagnosticComponent
    public let event: DiagnosticEvent
    public let requestID: UUID?
    public let action: DiagnosticAction?
    public let status: ReceiptStatus?
    public let errorCode: CommandErrorCode?
}

public struct DiagnosticLogLimits: Sendable {
    public let retentionSeconds: TimeInterval
    public let maximumBytes: Int
    public init(retentionSeconds: TimeInterval = 7 * 24 * 60 * 60, maximumBytes: Int = 10 * 1024 * 1024) {
        self.retentionSeconds = retentionSeconds.isFinite ? min(max(retentionSeconds, 0), 7 * 24 * 60 * 60) : 7 * 24 * 60 * 60
        self.maximumBytes = min(max(maximumBytes, 0), 10 * 1024 * 1024)
    }
}
public struct DiagnosticLogIssues: Codable, Sendable {
    public internal(set) var ioFailures = 0
    public internal(set) var invalidRecords = 0
    public internal(set) var unsupportedRecords = 0
    public internal(set) var futureRecords = 0
    public internal(set) var expiredRecords = 0
    public internal(set) var sanitizedRecords = 0
    public internal(set) var capacityDroppedRecords = 0
    public internal(set) var oversizedFiles = 0
    public var total: Int { ioFailures + invalidRecords + unsupportedRecords + futureRecords + expiredRecords + sanitizedRecords + capacityDroppedRecords + oversizedFiles }
}
public struct DiagnosticLogReport: Sendable {
    public internal(set) var persisted = false
    public internal(set) var retainedRecords = 0
    public internal(set) var retainedBytes = 0
    public internal(set) var issues = DiagnosticLogIssues()
}
public struct DiagnosticLogExport: Sendable {
    /// UTF-8 JSON Lines, freshly encoded from validated, typed records. Never original bytes.
    public let data: Data
    public let report: DiagnosticLogReport
}

/// A single bounded file. Calls are serialized in-process and take an advisory writer
/// lock across instances. Logging failure is reported as counts and never thrown to a task.
public final class DiagnosticLogStore: @unchecked Sendable {
    public let directory: URL
    public static let fileName = "events.jsonl"
    private let limits: DiagnosticLogLimits
    private let clock: () -> Date
    private let mutex = NSLock()
    public init(directory: URL, limits: DiagnosticLogLimits = .init(), clock: @escaping () -> Date = Date.init) {
        self.directory = directory; self.limits = limits; self.clock = clock
    }
    @discardableResult public func append(component: DiagnosticComponent, event: DiagnosticEvent,
                                          requestID: UUID? = nil, action: DiagnosticAction? = nil,
                                          status: ReceiptStatus? = nil, errorCode: CommandErrorCode? = nil) -> DiagnosticLogReport {
        transact { now in DiagnosticRecord(schemaVersion: 1, timestamp: now, component: component, event: event,
                                          requestID: requestID, action: action, status: status, errorCode: errorCode) }.report
    }
    public func export() -> DiagnosticLogExport { transact { _ in nil } }

    private func transact(_ makeRecord: (Date) -> DiagnosticRecord?) -> DiagnosticLogExport {
        mutex.lock(); defer { mutex.unlock() }
        var report = DiagnosticLogReport()
        var output = Data()
        do {
            let now = clock()
            guard now.timeIntervalSince1970.isFinite else { throw StoreError.invalid }
            let directoryFD = try openDirectory()
            defer { close(directoryFD) }
            let lockFD = openat(directoryFD, ".writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard lockFD >= 0 else { throw StoreError.io }
            defer { close(lockFD) }
            try validateFile(lockFD)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.io }
            defer { flock(lockFD, LOCK_UN) }
            let raw = try read(directoryFD, report: &report)
            var records = decode(raw, now: now, report: &report)
            if let record = makeRecord(now) {
                if limits.retentionSeconds > 0 { records.append(record) }
                else { report.issues.expiredRecords += 1 }
            }
            // Stable oldest-first ordering also handles a clock adjusted backwards.
            records = records.enumerated().sorted { lhs, rhs in
                lhs.element.timestamp == rhs.element.timestamp ? lhs.offset < rhs.offset : lhs.element.timestamp < rhs.element.timestamp
            }.map(\.element)
            let encoder = Self.encoder()
            var lines = try records.map { record -> Data in var line = try encoder.encode(record); line.append(0x0A); return line }
            var bytes = lines.reduce(0) { $0 + $1.count }
            var dropped = 0
            while dropped < lines.count && bytes > limits.maximumBytes { bytes -= lines[dropped].count; dropped += 1 }
            report.issues.capacityDroppedRecords += dropped
            if dropped > 0 { lines.removeFirst(dropped) }
            for line in lines { output.append(line) }
            report.retainedRecords = lines.count; report.retainedBytes = output.count
            try write(output, directoryFD: directoryFD)
            report.persisted = true
        } catch { report.issues.ioFailures += 1 }
        return DiagnosticLogExport(data: output, report: report)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    private func decode(_ data: Data, now: Date, report: inout DiagnosticLogReport) -> [DiagnosticRecord] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let allowed: Set<String> = ["schemaVersion", "timestamp", "component", "event", "requestID", "action", "status", "errorCode"]
        var result: [DiagnosticRecord] = []
        func consume(_ range: Range<Data.Index>) {
            guard !range.isEmpty else { return }
            guard range.count <= 2048 else { report.issues.invalidRecords += 1; return }
            let line = data.subdata(in: range)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let version = object["schemaVersion"] as? Int else { report.issues.invalidRecords += 1; return }
            guard version == 1 else { report.issues.unsupportedRecords += 1; return }
            guard let record = try? decoder.decode(DiagnosticRecord.self, from: line),
                  record.timestamp.timeIntervalSince1970.isFinite else { report.issues.invalidRecords += 1; return }
            guard record.timestamp <= now else { report.issues.futureRecords += 1; return }
            // At exactly seven days the record has reached its retention limit.
            guard record.timestamp > now.addingTimeInterval(-limits.retentionSeconds) else { report.issues.expiredRecords += 1; return }
            if !Set(object.keys).isSubset(of: allowed) { report.issues.sanitizedRecords += 1 }
            result.append(record)
        }
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A { consume(start..<index); start = index + 1 }
        consume(start..<data.endIndex)
        return result
    }

    private enum StoreError: Error { case invalid, io }
    /// Walk each component with openat so neither the log nor an ancestor symlink
    /// can redirect reads, rotation or writes. Only the final directory is created.
    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else { throw StoreError.invalid }
        let parts = directory.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { throw StoreError.invalid }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.io }
        do {
            for (index, part) in parts.enumerated() {
                var next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next < 0 && errno == ENOENT && index == parts.count - 1 {
                    guard mkdirat(descriptor, part, 0o700) == 0 || errno == EEXIST else { throw StoreError.io }
                    next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                guard next >= 0 else { throw StoreError.io }
                close(descriptor); descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StoreError.io }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private func validateFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw StoreError.io }
    }
    private func read(_ directoryFD: Int32, report: inout DiagnosticLogReport) throws -> Data {
        let descriptor = openat(directoryFD, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 && errno == ENOENT { return Data() }
        guard descriptor >= 0 else { throw StoreError.io }
        defer { close(descriptor) }
        try validateFile(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw StoreError.io }
        guard info.st_size <= 10 * 1024 * 1024 else { report.issues.oversizedFiles += 1; return Data() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let amount = Darwin.read(descriptor, &buffer, buffer.count)
            if amount == 0 { break }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw StoreError.io }
            guard result.count + amount <= 10 * 1024 * 1024 else { throw StoreError.io }
            result.append(contentsOf: buffer.prefix(amount))
        }
        return result
    }
    private func write(_ data: Data, directoryFD: Int32) throws {
        // A fixed reserved staging name bounds crash leftovers to one file. Never
        // truncate until its ownership/type/link count have been validated.
        let temporary = ".events.pending"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw StoreError.io }
        defer { close(descriptor) }
        try validateFile(descriptor)
        guard ftruncate(descriptor, 0) == 0 else { throw StoreError.io }
        defer { unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw StoreError.io }
                offset += amount
            }
        }
        guard fsync(descriptor) == 0 else { throw StoreError.io }
        var existing = stat()
        if fstatat(directoryFD, Self.fileName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(), existing.st_nlink == 1, existing.st_mode & 0o077 == 0 else { throw StoreError.io }
        } else if errno != ENOENT { throw StoreError.io }
        guard renameat(directoryFD, temporary, directoryFD, Self.fileName) == 0, fsync(directoryFD) == 0 else { throw StoreError.io }
    }
}
