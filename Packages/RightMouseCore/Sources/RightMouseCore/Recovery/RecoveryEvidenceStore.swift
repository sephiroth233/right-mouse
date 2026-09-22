import Foundation
import CryptoKit
import Darwin

public enum RecoveryEvidenceCategory: String, Codable, Sendable { case commands, transfers, followups
    fileprivate var directory: String { switch self { case .commands: return "Commands"; case .transfers: return "Transfers"; case .followups: return "Followups" } }
}
public struct RecoveryEvidenceLimits: Sendable {
    public var maximumFileBytes: Int
    public var maximumTotalBytes: Int
    public var maximumRecords: Int
    public init(maximumFileBytes: Int = 8 * 1024 * 1024, maximumTotalBytes: Int = 64 * 1024 * 1024, maximumRecords: Int = 1024) {
        self.maximumFileBytes = maximumFileBytes; self.maximumTotalBytes = maximumTotalBytes; self.maximumRecords = maximumRecords
    }
    public static let `default` = Self()
}
public enum RecoveryEvidenceFailure: String, Codable, Sendable { case invalidLocation, unsafeFile, oversized, capacityExceeded, backupConflict, busy, ioFailure }
public struct RecoveryEvidenceResult: Sendable {
    public enum Status: String, Sendable { case created, alreadyPreserved, failed }
    public let status: Status
    public let failureCode: RecoveryEvidenceFailure?
    public let byteCount: Int
    fileprivate init(_ status: Status, failure: RecoveryEvidenceFailure? = nil, byteCount: Int = 0) { self.status = status; failureCode = failure; self.byteCount = byteCount }
}
/// Recovery copies contain private raw evidence. Never include this store in diagnostics exports.
public struct RecoveryEvidenceMetadata: Codable, Sendable {
    public let schemaVersion: Int
    public let category: RecoveryEvidenceCategory
    public let recordID: UUID
    public let contentSHA256: String
    public let byteCount: Int
    public let preservedAt: Date
}

public struct RecoveryEvidenceStore: Sendable {
    public let paths: SharedPaths
    public let backupRoot: URL
    public let limits: RecoveryEvidenceLimits
    public init(paths: SharedPaths, backupRoot: URL, limits: RecoveryEvidenceLimits = .default) { self.paths = paths; self.backupRoot = backupRoot; self.limits = limits }

    /// Does not decode business records, delete originals, replay operations, or recycle
    /// unreviewed evidence. Every error is reduced to a path-free failure category.
    public func preserve(sourceURL: URL, category: RecoveryEvidenceCategory, recordID: UUID, now: Date = Date()) -> RecoveryEvidenceResult {
        do {
            let privateRoot = paths.operationsDirectory.deletingLastPathComponent()
            let expected = paths.operationsDirectory.appendingPathComponent(category.directory).appendingPathComponent(recordID.uuidString + ".json")
            guard local(sourceURL), local(backupRoot), sourceURL.standardizedFileURL == expected.standardizedFileURL else { throw EvidenceError(.invalidLocation) }
            let rootComponents = privateRoot.standardizedFileURL.pathComponents
            let backupComponents = backupRoot.standardizedFileURL.pathComponents
            guard backupComponents.count > rootComponents.count, backupComponents.count <= rootComponents.count + 4,
                  Array(backupComponents.prefix(rootComponents.count)) == rootComponents,
                  backupComponents[rootComponents.count] == "Backups" else { throw EvidenceError(.invalidLocation) }
            let maximumFile = min(limits.maximumFileBytes, 8 * 1024 * 1024)
            let maximumTotal = min(limits.maximumTotalBytes, 64 * 1024 * 1024)
            let maximumRecords = min(limits.maximumRecords, 1024)
            guard maximumFile > 0, maximumTotal > 0, maximumRecords > 0 else { throw EvidenceError(.capacityExceeded) }
            let root = try EvidenceDirectory(root: privateRoot)
            let operations = try root.child("Operations")
            let sourceDirectory = try operations.child(category.directory)
            let original = try sourceDirectory.read(recordID.uuidString + ".json", maximumBytes: maximumFile)
            let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            var backup = root
            for component in backupComponents.dropFirst(rootComponents.count) { backup = try backup.child(component, create: true) }
            let lock = try backup.lock()
            defer { flock(lock, LOCK_UN); close(lock) }
            let stem = category.rawValue + "-" + recordID.uuidString + "-" + hash
            let bytesName = stem + ".bytes", metadataName = stem + ".json"
            let metadata = RecoveryEvidenceMetadata(schemaVersion: 1, category: category, recordID: recordID, contentSHA256: hash, byteCount: original.count, preservedAt: now)
            let metadataBytes = try WireCodec.encoder().encode(metadata)
            let existingBytes = try backup.optionalRead(bytesName, maximumBytes: maximumFile)
            let existingMetadata = try backup.optionalRead(metadataName, maximumBytes: 4096)
            if let existingBytes { guard existingBytes == original else { throw EvidenceError(.backupConflict) } }
            if let existingMetadata {
                let old = try WireCodec.decoder().decode(RecoveryEvidenceMetadata.self, from: existingMetadata)
                guard old.schemaVersion == 1, old.category == category, old.recordID == recordID, old.contentSHA256 == hash, old.byteCount == original.count else { throw EvidenceError(.backupConflict) }
            }
            if existingBytes != nil && existingMetadata != nil { return .init(.alreadyPreserved, byteCount: original.count) }
            let usage = try backup.usage(maximumEntries: 2 * maximumRecords + 1)
            let additional = (existingBytes == nil ? original.count : 0) + (existingMetadata == nil ? metadataBytes.count : 0)
            guard usage.bytes <= maximumTotal - additional, usage.records + (existingBytes == nil ? 1 : 0) <= maximumRecords else { throw EvidenceError(.capacityExceeded) }
            // Exclusive creation: an interrupted partial pair may be completed only
            // when the existing member exactly matches; it is never overwritten.
            if existingBytes == nil { try backup.create(bytesName, data: original) }
            if existingMetadata == nil { try backup.create(metadataName, data: metadataBytes) }
            return .init(.created, byteCount: original.count)
        } catch let error as EvidenceError { return .init(.failed, failure: error.code) }
        catch { return .init(.failed, failure: .ioFailure) }
    }
    private func local(_ url: URL) -> Bool { url.isFileURL && (url.host ?? "").isEmpty && url.query == nil && url.fragment == nil && !url.path.contains("\0") }
}

private struct EvidenceError: Error { let code: RecoveryEvidenceFailure; init(_ code: RecoveryEvidenceFailure) { self.code = code } }
private final class EvidenceDirectory {
    let fd: Int32
    init(fd: Int32) throws {
        guard fd >= 0 else { throw EvidenceError(.unsafeFile) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw EvidenceError(.unsafeFile) }
        self.fd = fd
    }
    convenience init(root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, let physical = realpath(root.path, nil) else { throw EvidenceError(.unsafeFile) }
        defer { free(physical) }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        for component in String(cString: physical).split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(descriptor); descriptor = next
            guard descriptor >= 0 else { throw EvidenceError(.unsafeFile) }
        }
        try self.init(fd: descriptor)
    }
    deinit { close(fd) }
    func child(_ name: String, create: Bool = false) throws -> EvidenceDirectory {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw EvidenceError(.invalidLocation) }
        if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw EvidenceError(.ioFailure) }
        return try EvidenceDirectory(fd: openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW))
    }
    func checkedFile(_ name: String, flags: Int32, mode: mode_t = 0o600) throws -> Int32 {
        let descriptor = openat(fd, name, flags | O_NOFOLLOW | O_NONBLOCK, mode)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw POSIXError(.ENOENT) }
            throw EvidenceError(.unsafeFile)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else { close(descriptor); throw EvidenceError(.unsafeFile) }
        return descriptor
    }
    func lock() throws -> Int32 {
        let descriptor = try checkedFile(".evidence.lock", flags: O_RDWR | O_CREAT)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw EvidenceError(.busy) }
        return descriptor
    }
    func optionalRead(_ name: String, maximumBytes: Int) throws -> Data? {
        do { return try read(name, maximumBytes: maximumBytes) } catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    func read(_ name: String, maximumBytes: Int) throws -> Data {
        let descriptor = try checkedFile(name, flags: O_RDONLY)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(); guard fstat(descriptor, &before) == 0 else { throw EvidenceError(.ioFailure) }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw EvidenceError(.oversized) }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw EvidenceError(.unsafeFile) }
        return data
    }
    func create(_ name: String, data: Data) throws {
        let descriptor = try checkedFile(name, flags: O_WRONLY | O_CREAT | O_EXCL)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard fsync(fd) == 0 else { throw EvidenceError(.ioFailure) }
    }
    func usage(maximumEntries: Int) throws -> (bytes: Int, records: Int) {
        guard let stream = fdopendir(dup(fd)) else { throw EvidenceError(.ioFailure) }
        defer { closedir(stream) }
        var bytes = 0, records = 0, entries = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name == "." || name == ".." || name == ".evidence.lock" { continue }
            entries += 1; guard entries <= maximumEntries else { throw EvidenceError(.capacityExceeded) }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size >= 0,
                  info.st_size <= 64 * 1024 * 1024 else { throw EvidenceError(.unsafeFile) }
            bytes += Int(info.st_size)
            if name.hasSuffix(".bytes") { records += 1 }
        }
        return (bytes, records)
    }
}
