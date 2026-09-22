import Foundation
import RightMouseCore

/// Follow-up actions never rewrite the outcome of the original file operation.
struct TaskFollowupRecord: Codable {
    var schemaVersion = 1
    let requestID: UUID
    var destination: URL?
    var destinationIdentity: String?
    var result: TransferResult?
    var accessBookmarks: [Data] = []
    var undoStarted: Set<UUID> = []
    var undoCompleted: Set<UUID> = []
    var retryRequestID: UUID?
    var requiresReview: Bool { !undoStarted.subtracting(undoCompleted).isEmpty }
}

struct TaskFollowupStore {
    let directory: URL
    func read(_ id: UUID) throws -> TaskFollowupRecord? {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        do {
            let record = try WireCodec.decoder().decode(TaskFollowupRecord.self, from: PrivateFileIO.read(url, maximumBytes: 8 * RequestValidator.maximumBytes))
            guard record.schemaVersion == 1, record.requestID == id,
                  record.result == nil || record.result?.operationID == id,
                  record.undoCompleted.isSubset(of: record.undoStarted),
                  record.destination == nil || record.destination?.isFileURL == true else {
                throw CommandFailure(.recoveryRequired, "后续操作记录不兼容或标识不一致，请核对任务")
            }
            if let result = record.result {
                let itemIDs = Set(result.items.map(\.itemID))
                let undoableIDs = Set(result.items.filter { $0.status == .completed && $0.undoToken != nil }.map(\.itemID))
                guard itemIDs.count == result.items.count, record.undoStarted.isSubset(of: undoableIDs) else {
                    throw CommandFailure(.recoveryRequired, "撤销记录与原项目不一致，请核对任务")
                }
                for item in result.items {
                    try validateLocal(item.source)
                    if let destination = item.destination { try validateLocal(destination) }
                    if let token = item.undoToken {
                        try validateLocal(token.originalURL); try validateLocal(token.currentURL)
                        guard token.originalURL == item.source, token.currentURL == item.destination else { throw CommandFailure(.recoveryRequired, "撤销位置与原项目不一致") }
                    }
                }
            } else if !record.undoStarted.isEmpty || record.retryRequestID != nil {
                throw CommandFailure(.recoveryRequired, "缺少原任务结果，不能继续后续操作")
            }
            if let destination = record.destination { try validateLocal(destination) }
            return record
        } catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    private func validateLocal(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty, url.query == nil, url.fragment == nil, !url.path.contains("\0") else { throw CommandFailure(.recoveryRequired, "后续操作包含非法文件位置") }
    }
    func save(_ record: TaskFollowupRecord) throws {
        try PrivateFileIO.write(WireCodec.encoder().encode(record), to: directory.appendingPathComponent(record.requestID.uuidString + ".json"))
    }
}
