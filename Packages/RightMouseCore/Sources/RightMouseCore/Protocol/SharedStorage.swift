import Foundation
import CryptoKit
import Darwin

public struct SharedPaths: Sendable {
    public enum DevelopmentReason: String, Sendable {
        case explicitDirectory, sharedContainerUnavailable, sharedContainerUnwritable
    }
    /// Explicit inputs let fixture tests exercise permission failures without writing
    /// into a user's App Group or changing any system authorization.
    public struct ResolutionEnvironment: Sendable {
        public var appGroup: String
        public var isExtension: Bool
        public var allowsDevelopmentFallback: Bool
        public var developmentDirectory: String?
        public init(appGroup: String, isExtension: Bool, allowsDevelopmentFallback: Bool, developmentDirectory: String? = nil) {
            self.appGroup = appGroup; self.isExtension = isExtension
            self.allowsDevelopmentFallback = allowsDevelopmentFallback; self.developmentDirectory = developmentDirectory
        }
        public static var current: Self {
            Self(appGroup: Bundle.main.object(forInfoDictionaryKey: "RightMouseAppGroup") as? String ?? "group.cn.rightmouse.shared",
                 isExtension: Bundle.main.bundleURL.pathExtension == "appex",
                 allowsDevelopmentFallback: Bundle.main.object(forInfoDictionaryKey: "RightMouseAllowDevelopmentStorageFallback") as? Bool == true,
                 developmentDirectory: ProcessInfo.processInfo.environment["RIGHTMOUSE_DATA_DIR"])
        }
    }
    public let root: URL
    public let isDevelopmentFallback: Bool
    public let developmentReason: DevelopmentReason?
    public var configurationDirectory: URL { root.appendingPathComponent("Configuration", isDirectory: true) }
    public var templatesDirectory: URL { root.appendingPathComponent("Templates", isDirectory: true) }
    public var operationsDirectory: URL { root.appendingPathComponent("Operations", isDirectory: true) }
    public var inboxDirectory: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var receiptsDirectory: URL { root.appendingPathComponent("Receipts", isDirectory: true) }
    public var pendingMoveURL: URL { root.appendingPathComponent("pending-move.json") }
    public var developmentDiagnostic: String? {
        guard isDevelopmentFallback else { return nil }
        let reason: String
        switch developmentReason {
        case .explicitDirectory: reason = "已指定开发测试目录。"
        case .sharedContainerUnavailable: reason = "共享容器尚不可用，已切换到独立的本地开发目录。"
        case .sharedContainerUnwritable: reason = "共享容器无法写入，已切换到独立的本地开发目录。"
        case nil: reason = "正在使用独立的本地开发目录。"
        }
        return "开发模式：\(reason)应用内文件操作可用，Finder 右键功能不可用。完成宿主与扩展的 App Group 签名配置后，再验证 Finder 功能。"
    }
    public init(root: URL, isDevelopmentFallback: Bool = false, developmentReason: DevelopmentReason? = nil) {
        self.root = root; self.isDevelopmentFallback = isDevelopmentFallback; self.developmentReason = developmentReason
    }
    /// Read-only path selection used by the Finder extension. It never probes or
    /// creates host storage, and extensions never accept a development override.
    public static func resolve() throws -> SharedPaths {
        try resolveAndPrepare(environment: .current,
            groupContainer: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
            applicationSupport: applicationSupportDirectory,
            prepare: { _ in })
    }
    /// Host startup verifies actual access: macOS can return a group URL even when
    /// it will reject the subsequent write. Only flagged development hosts degrade.
    public static func resolveAndPrepare() throws -> SharedPaths {
        try resolveAndPrepare(environment: .current,
            groupContainer: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
            applicationSupport: applicationSupportDirectory,
            prepare: { paths in try paths.prepare(); try paths.verifyWritableStorage() })
    }
    public static func resolveAndPrepare(environment: ResolutionEnvironment,
                                        groupContainer: (String) -> URL?,
                                        applicationSupport: () throws -> URL,
                                        prepare: (SharedPaths) throws -> Void) throws -> SharedPaths {
        let allowLocal = environment.allowsDevelopmentFallback && !environment.isExtension
        if let override = environment.developmentDirectory, !override.isEmpty {
            guard allowLocal else { throw CommandFailure(.accessDenied, "当前构建不允许开发数据目录覆盖。Finder 扩展与正式构建必须使用授权共享容器。") }
            guard override.hasPrefix("/"), !override.contains("\0") else { throw CommandFailure(.invalidRequest, "开发数据目录必须是有效的绝对路径。") }
            let paths = SharedPaths(root: URL(fileURLWithPath: override, isDirectory: true), isDevelopmentFallback: true, developmentReason: .explicitDirectory)
            try prepare(paths)
            return paths
        }
        let fallbackReason: DevelopmentReason
        if let directory = groupContainer(environment.appGroup) {
            let shared = SharedPaths(root: directory.appendingPathComponent("RightMouse", isDirectory: true))
            do { try prepare(shared); return shared }
            catch {
                guard allowLocal else { throw error }
                fallbackReason = .sharedContainerUnwritable
            }
        } else {
            guard allowLocal else { throw CommandFailure(.accessDenied, "无法访问共享容器，请检查宿主与 Finder 扩展的签名和 App Group 配置。") }
            fallbackReason = .sharedContainerUnavailable
        }
        let local = try applicationSupport().appendingPathComponent("RightMouse-Development", isDirectory: true)
        let paths = SharedPaths(root: local, isDevelopmentFallback: true, developmentReason: fallbackReason)
        try prepare(paths)
        return paths
    }
    private static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
    public func prepare() throws {
        for url in [root,configurationDirectory,templatesDirectory,operationsDirectory,inboxDirectory,receiptsDirectory] { try PrivateFileIO.ensureDirectory(url) }
    }
    private func verifyWritableStorage() throws {
        let marker = UUID().uuidString
        let probe = root.appendingPathComponent(".storage-probe-" + marker)
        defer { try? FileManager.default.removeItem(at: probe) }
        let data = Data(marker.utf8)
        try PrivateFileIO.write(data, to: probe, replace: false)
        guard try PrivateFileIO.read(probe, maximumBytes: 128) == data else { throw CommandFailure(.ioFailed, "应用数据目录读写校验失败。") }
        try FileManager.default.removeItem(at: probe)
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
