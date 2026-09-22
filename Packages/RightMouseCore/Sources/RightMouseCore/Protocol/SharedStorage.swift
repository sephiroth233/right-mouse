import Foundation
import CryptoKit
import Darwin

public struct SharedPaths: Sendable {
    public let root: URL
    public let isDevelopmentFallback: Bool
    public var configurationDirectory: URL { root.appendingPathComponent("Configuration", isDirectory: true) }
    public var templatesDirectory: URL { root.appendingPathComponent("Templates", isDirectory: true) }
    public var operationsDirectory: URL { root.appendingPathComponent("Operations", isDirectory: true) }
    public var inboxDirectory: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var receiptsDirectory: URL { root.appendingPathComponent("Receipts", isDirectory: true) }
    public var pendingMoveURL: URL { root.appendingPathComponent("pending-move.json") }
    public init(root: URL, isDevelopmentFallback: Bool = false) { self.root = root; self.isDevelopmentFallback = isDevelopmentFallback }
    public static func resolve() throws -> SharedPaths {
        if let override = ProcessInfo.processInfo.environment["RIGHTMOUSE_DATA_DIR"], !override.isEmpty {
            return SharedPaths(root: URL(fileURLWithPath: override, isDirectory: true), isDevelopmentFallback: true)
        }
        let group = Bundle.main.object(forInfoDictionaryKey: "RightMouseAppGroup") as? String ?? "group.cn.rightmouse.shared"
        if let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return SharedPaths(root: directory.appendingPathComponent("RightMouse", isDirectory: true))
        }
        if Bundle.main.bundleURL.pathExtension == "appex" { throw CommandFailure(.accessDenied, "Finder 扩展无法访问共享容器，请检查签名与 App Group 配置") }
        let library = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return SharedPaths(root: library.appendingPathComponent("RightMouse", isDirectory: true), isDevelopmentFallback: true)
    }
    public func prepare() throws {
        for url in [root,configurationDirectory,templatesDirectory,operationsDirectory,inboxDirectory,receiptsDirectory] { try PrivateFileIO.ensureDirectory(url) }
    }
}

public enum PrivateFileIO {
    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else { throw CommandFailure(.accessDenied, "应用数据目录不可信") }
    }
    public static func write(_ data: Data, to url: URL, replace: Bool = true) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        let result = replace ? rename(temporary.path, url.path) : renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    public static func read(_ url: URL, maximumBytes: Int = RequestValidator.maximumBytes) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw CommandFailure(.accessDenied, "请求文件不可信") }
        guard info.st_size <= maximumBytes else { throw CommandFailure(.limitExceeded, "请求文件过大") }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CommandFailure(.limitExceeded, "请求文件过大") }
        return data
    }
}

public struct InboxStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func enqueue(_ request: CommandRequest) throws {
        let data = try WireCodec.encoder().encode(request)
        _ = try RequestValidator.decode(data); try RequestValidator.validateFresh(request)
        let path = directory.appendingPathComponent(request.requestID.uuidString + ".json")
        do { try PrivateFileIO.write(data, to: path, replace: false) }
        catch let error as POSIXError where error.code == .EEXIST {
            let old = try RequestValidator.decode(PrivateFileIO.read(path))
            guard try WireCodec.encoder().encode(old) == WireCodec.encoder().encode(request) else { throw CommandFailure(.requestIDConflict, "请求标识与已有内容冲突") }
        }
    }
    public func request(_ id: UUID) throws -> CommandRequest {
        let request = try RequestValidator.decode(PrivateFileIO.read(directory.appendingPathComponent(id.uuidString + ".json")))
        guard request.requestID == id else { throw CommandFailure(.invalidRequest, "请求文件名不匹配") }
        return request
    }
    public func pendingIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }
    public func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json")) }
}

public struct LedgerEntry: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var request: CommandRequest
    public var digest: String
    public var receipt: CommandReceipt

    enum CodingKeys: String, CodingKey { case schemaVersion, request, digest, receipt }
    public init(request: CommandRequest, digest: String, receipt: CommandReceipt) {
        self.request = request; self.digest = digest; self.receipt = receipt
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        request = try values.decode(CommandRequest.self, forKey: .request)
        digest = try values.decode(String.self, forKey: .digest)
        receipt = try values.decode(CommandReceipt.self, forKey: .receipt)
    }
}

public struct LedgerIssue: Sendable {
    public let url: URL
    public let message: String
    public init(url: URL, message: String) { self.url = url; self.message = message }
}

public struct LedgerScan: Sendable {
    public let entries: [LedgerEntry]
    public let issues: [LedgerIssue]
    public init(entries: [LedgerEntry], issues: [LedgerIssue]) { self.entries = entries; self.issues = issues }
}
public final class CommandLedger {
    public let directory: URL
    private var lockDescriptor: Int32 = -1
    public init(directory: URL) throws {
        self.directory = directory
        try PrivateFileIO.ensureDirectory(directory)
        lockDescriptor = open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { if lockDescriptor >= 0 { close(lockDescriptor) }; lockDescriptor = -1; throw CommandFailure(.ioFailed, "另一个 RightMouse 实例正在处理任务") }
    }
    deinit { if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) } }
    public func entry(_ id: UUID) throws -> LedgerEntry? {
        let path = directory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try validatedEntry(at: path, expectedID: id)
    }
    public func accept(_ request: CommandRequest, now: Date = Date()) throws -> (entry: LedgerEntry, isNew: Bool) {
        let digest = SHA256.hash(data: try WireCodec.encoder().encode(request)).map { String(format: "%02x", $0) }.joined()
        if let existing = try entry(request.requestID) {
            guard existing.digest == digest else { throw CommandFailure(.requestIDConflict, "请求标识重复但内容不同") }
            return (existing, false)
        }
        try RequestValidator.validateFresh(request, now: now)
        let entry = LedgerEntry(request: request, digest: digest, receipt: CommandReceipt(requestID: request.requestID))
        try save(entry); return (entry, true)
    }
    public func save(_ entry: LedgerEntry) throws {
        try PrivateFileIO.write(WireCodec.encoder().encode(entry), to: directory.appendingPathComponent(entry.request.requestID.uuidString + ".json"))
    }
    public func entries() throws -> [LedgerEntry] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try validatedEntry(at: $0, expectedID: UUID(uuidString: $0.deletingPathExtension().lastPathComponent)) }
    }
    public func scanEntries() throws -> LedgerScan {
        var entries: [LedgerEntry] = [], issues: [LedgerIssue] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) {
            do {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    throw CommandFailure(.invalidRequest, "操作记录文件名不是 UUID")
                }
                entries.append(try validatedEntry(at: url, expectedID: id))
            } catch {
                issues.append(LedgerIssue(url: url, message: error.localizedDescription))
            }
        }
        return LedgerScan(entries: entries, issues: issues)
    }
    private func validatedEntry(at url: URL, expectedID: UUID?) throws -> LedgerEntry {
        let entry = try WireCodec.decoder().decode(LedgerEntry.self, from: PrivateFileIO.read(url, maximumBytes: 8 * RequestValidator.maximumBytes))
        guard entry.schemaVersion == 1 else { throw CommandFailure(.unsupportedVersion, "不支持的操作记录版本") }
        guard entry.request.schemaVersion == 1, entry.receipt.schemaVersion == 1,
              entry.receipt.requestID == entry.request.requestID,
              expectedID == nil || expectedID == entry.request.requestID else {
            throw CommandFailure(.invalidRequest, "操作记录标识不一致")
        }
        let digest = SHA256.hash(data: try WireCodec.encoder().encode(entry.request)).map { String(format: "%02x", $0) }.joined()
        guard entry.digest == digest else { throw CommandFailure(.invalidRequest, "操作记录摘要不一致") }
        return entry
    }
}
