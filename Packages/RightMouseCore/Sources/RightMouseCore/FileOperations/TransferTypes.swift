import Foundation

public enum TransferMode: String, Codable, Sendable { case copy, move }
public enum TransferConflictPolicy: String, Codable, Sendable { case ask, skip, keepBoth }
public enum TransferConflictDecision: String, Codable, Sendable { case skip, keepBoth, cancel }
public enum TransferItemStatus: String, Codable, Sendable { case completed, skipped, failed, cancelled, sourceRetained, needsReview }

public final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public struct TransferProgress: Sendable {
    public let operationID: UUID
    public let completedItems: Int
    public let totalItems: Int
    public let phase: String
    public let bytesProcessed: Int64
}

public struct TransferFileIdentity: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: UInt32
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
}

public struct TransferUndoToken: Codable, Sendable {
    public let originalURL: URL
    public let currentURL: URL
    public let identity: TransferFileIdentity
    public let contentFingerprint: String
}

public struct TransferItemResult: Codable, Sendable {
    public let itemID: UUID
    public let operationID: UUID?
    public let source: URL
    public let destination: URL?
    public let status: TransferItemStatus
    public let message: String
    public let failure: CommandFailure?
    public let undoToken: TransferUndoToken?
    public init(itemID: UUID = UUID(), operationID: UUID? = nil, source: URL, destination: URL? = nil, status: TransferItemStatus, message: String, failure: CommandFailure? = nil, undoToken: TransferUndoToken? = nil) {
        self.itemID = itemID; self.operationID = operationID; self.source = source; self.destination = destination; self.status = status; self.message = message; self.failure = failure; self.undoToken = undoToken
    }
}

public struct TransferResult: Codable, Sendable {
    public let operationID: UUID
    public let items: [TransferItemResult]
    public var completedCount: Int { items.filter { $0.status == .completed }.count }
    public var state: String {
        if items.contains(where: { $0.status == .needsReview }) { return "needsReview" }
        if items.allSatisfy({ $0.status == .completed || $0.status == .skipped }) {
            return completedCount > 0 && completedCount < items.count ? "partial" : "completed"
        }
        if completedCount > 0 || items.contains(where: { $0.status == .sourceRetained }) { return "partial" }
        if items.contains(where: { $0.status == .cancelled }) { return "cancelled" }
        return "failed"
    }
}

/// Private recovery journal, containing paths for explicit user recovery (never diagnostic logging).
public struct TransferJournalRecord: Codable, Sendable {
    public var schemaVersion = 1
    public let operationID: UUID
    public let itemID: UUID
    public let source: URL
    public var destination: URL
    public let mode: TransferMode
    public var phase: String
    public var sourceIdentity: TransferFileIdentity?
    public var destinationIdentity: TransferFileIdentity?
    public var stagingURL: URL?
    /// Present only for staging created by versions that can prove ownership.
    public var stagingIdentity: TransferFileIdentity?
    public var stagingParentIdentity: TransferFileIdentity?
    public var stagingCleanupURL: URL?
    public var stagingCleanupState: StagingCleanupState?
    public var result: TransferItemResult?
}

public enum StagingCleanupState: String, Codable, Sendable { case requested, completed, needsReview }

public struct StagingCleanupToken: Codable, Sendable {
    public let operationID: UUID
    public let itemID: UUID
    public let journalURL: URL
    public let stagingURL: URL
    public let stagingIdentity: TransferFileIdentity
    public let parentIdentity: TransferFileIdentity
    public let journalDigest: String
    public init(operationID: UUID, itemID: UUID, journalURL: URL, stagingURL: URL,
                stagingIdentity: TransferFileIdentity, parentIdentity: TransferFileIdentity, journalDigest: String) {
        self.operationID = operationID; self.itemID = itemID; self.journalURL = journalURL; self.stagingURL = stagingURL
        self.stagingIdentity = stagingIdentity; self.parentIdentity = parentIdentity; self.journalDigest = journalDigest
    }
}

public enum StagingRecoveryDisposition: Sendable {
    case cleanupAllowed(StagingCleanupToken)
    case legacyEvidenceOnly(String)
    case retainedForReview(String)
}

public struct StagingRecoveryItem: Sendable {
    public let operationID: UUID
    public let itemID: UUID
    public let stagingURL: URL?
    public let occupiedBytes: Int64
    public let disposition: StagingRecoveryDisposition
    public init(operationID: UUID, itemID: UUID, stagingURL: URL?, occupiedBytes: Int64, disposition: StagingRecoveryDisposition) {
        self.operationID = operationID; self.itemID = itemID; self.stagingURL = stagingURL
        self.occupiedBytes = occupiedBytes; self.disposition = disposition
    }
}

public struct StagingRecoveryInspection: Sendable {
    public let items: [StagingRecoveryItem]
    public let issues: [TransferRecoveryIssue]
}

public struct StagingCleanupResult: Sendable {
    public let operationID: UUID
    public let itemID: UUID
    public let removedBytes: Int64
}

public struct TransferRecoveryIssue: Sendable {
    public let url: URL
    public let message: String
    public init(url: URL, message: String) { self.url = url; self.message = message }
}

public struct TransferRecoveryScan: Sendable {
    public let records: [TransferJournalRecord]
    public let issues: [TransferRecoveryIssue]
    public init(records: [TransferJournalRecord], issues: [TransferRecoveryIssue]) { self.records = records; self.issues = issues }
}

public enum TransferEngineError: Error, LocalizedError {
    case invalidTarget, invalidSource, descendantTarget, sourceChanged, verificationFailed, cancelled, occupied, unsafeUndo, unsupportedFile, journalVersion, system(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidTarget: return "目标必须是存在且可访问的文件夹。"
        case .invalidSource: return "来源不存在或不是本地文件。"
        case .descendantTarget: return "不能把文件夹复制或移动到它自身的子目录。"
        case .sourceChanged: return "来源在操作期间变化，已保留来源，请核对。"
        case .verificationFailed: return "内容或必要元数据校验失败，已保留来源。"
        case .cancelled: return "操作已取消。"
        case .occupied: return "目标已被其他文件占用，未覆盖。"
        case .unsafeUndo: return "文件已改变或原路径被占用，无法安全撤销。"
        case .unsupportedFile: return "不支持 FIFO、socket 或设备文件。"
        case .journalVersion: return "操作记录版本不受支持，请保留现场并核对。"
        case .system(let code): return String(cString: strerror(code))
        }
    }
}
