import Foundation

public enum FileKind: String, Codable, Sendable { case file, directory, symlink, unknown }
public enum EntryPoint: String, Codable, Sendable { case items, container, sidebar, toolbar }
public enum CopyTextFormat: String, Codable, Sendable { case path, name, stem, shellPath }
public enum ConflictPolicy: String, Codable, Sendable { case ask, skip, keepBoth }
public enum CommandTransferMode: String, Codable, Sendable { case copy, move }
public enum OpenMode: String, Codable, Sendable { case files, directory }

public struct FileReference: Codable, Sendable, Equatable {
    public var refID: UUID
    public var url: URL
    public var kindHint: FileKind
    public var bookmarkToken: UUID?
    enum CodingKeys: String, CodingKey { case refID, url = "fileURL", kindHint, bookmarkToken }
    public init(refID: UUID = UUID(), url: URL, kindHint: FileKind = .unknown, bookmarkToken: UUID? = nil) {
        self.refID = refID; self.url = url; self.kindHint = kindHint; self.bookmarkToken = bookmarkToken
    }
}

public struct ActionContext: Codable, Sendable, Equatable {
    public var invocationID: UUID
    public var entryPoint: EntryPoint
    public var container: FileReference?
    public var selection: [FileReference]
    public init(invocationID: UUID = UUID(), entryPoint: EntryPoint, container: FileReference?, selection: [FileReference]) {
        self.invocationID = invocationID; self.entryPoint = entryPoint; self.container = container; self.selection = selection
    }
    enum CodingKeys: String, CodingKey { case invocationID, entryPoint, container, selection }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(invocationID, forKey: .invocationID); try c.encode(entryPoint, forKey: .entryPoint)
        try c.encode(container, forKey: .container); try c.encode(selection, forKey: .selection)
    }
}

public enum CommandAction: Codable, Sendable, Equatable {
    case createFile(templateID: String, destination: FileReference?, name: String?)
    case copyText(format: CopyTextFormat)
    case stageMove
    case pasteMove(pendingToken: UUID, destination: FileReference?, conflictPolicy: ConflictPolicy)
    case transfer(mode: CommandTransferMode, destination: FileReference?, conflictPolicy: ConflictPolicy)
    case openFavorite(favoriteID: UUID)
    case openWith(integrationID: String, mode: OpenMode)

    public var type: String {
        switch self {
        case .createFile: return "createFile"
        case .copyText: return "copyText"
        case .stageMove: return "stageMove"
        case .pasteMove: return "pasteMove"
        case .transfer: return "transfer"
        case .openFavorite: return "openFavorite"
        case .openWith: return "openWith"
        }
    }
    public var changesFiles: Bool {
        switch self { case .createFile, .pasteMove, .transfer: return true; default: return false }
    }
    enum CodingKeys: String, CodingKey { case type, templateID, destination, name, format, pendingToken, conflictPolicy, mode, favoriteID, integrationID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "createFile": self = .createFile(templateID: try c.decode(String.self, forKey: .templateID), destination: try c.decodeIfPresent(FileReference.self, forKey: .destination), name: try c.decodeIfPresent(String.self, forKey: .name))
        case "copyText": self = .copyText(format: try c.decode(CopyTextFormat.self, forKey: .format))
        case "stageMove": self = .stageMove
        case "pasteMove": self = .pasteMove(pendingToken: try c.decode(UUID.self, forKey: .pendingToken), destination: try c.decodeIfPresent(FileReference.self, forKey: .destination), conflictPolicy: try c.decode(ConflictPolicy.self, forKey: .conflictPolicy))
        case "transfer": self = .transfer(mode: try c.decode(CommandTransferMode.self, forKey: .mode), destination: try c.decodeIfPresent(FileReference.self, forKey: .destination), conflictPolicy: try c.decode(ConflictPolicy.self, forKey: .conflictPolicy))
        case "openFavorite": self = .openFavorite(favoriteID: try c.decode(UUID.self, forKey: .favoriteID))
        case "openWith": self = .openWith(integrationID: try c.decode(String.self, forKey: .integrationID), mode: try c.decode(OpenMode.self, forKey: .mode))
        default: throw CommandFailure(.invalidRequest, "未知命令")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case let .createFile(templateID, destination, name):
            try c.encode(templateID, forKey: .templateID); try c.encode(destination, forKey: .destination); try c.encodeIfPresent(name, forKey: .name)
        case let .copyText(format): try c.encode(format, forKey: .format)
        case .stageMove: break
        case let .pasteMove(token, destination, policy):
            try c.encode(token, forKey: .pendingToken); try c.encode(destination, forKey: .destination); try c.encode(policy, forKey: .conflictPolicy)
        case let .transfer(mode, destination, policy):
            try c.encode(mode, forKey: .mode); try c.encode(destination, forKey: .destination); try c.encode(policy, forKey: .conflictPolicy)
        case let .openFavorite(id): try c.encode(id, forKey: .favoriteID)
        case let .openWith(id, mode): try c.encode(id, forKey: .integrationID); try c.encode(mode, forKey: .mode)
        }
    }
}

public struct CommandRequest: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var requestID: UUID
    public var producerInstanceID: UUID
    public var createdAt: Date
    public var expiresAt: Date
    public var context: ActionContext
    public var action: CommandAction
    public init(context: ActionContext, action: CommandAction, producerInstanceID: UUID = UUID(), now: Date = Date(), requestID: UUID = UUID()) {
        self.requestID = requestID; self.producerInstanceID = producerInstanceID; createdAt = now; expiresAt = now.addingTimeInterval(120)
        self.context = context; self.action = action
    }
}

public enum CommandErrorCode: String, Codable, Sendable {
    case invalidRequest = "INVALID_REQUEST", unsupportedVersion = "UNSUPPORTED_VERSION", requestExpired = "REQUEST_EXPIRED", requestIDConflict = "REQUEST_ID_CONFLICT"
    case contextUnavailable = "CONTEXT_UNAVAILABLE", limitExceeded = "LIMIT_EXCEEDED", accessDenied = "ACCESS_DENIED", bookmarkStale = "BOOKMARK_STALE"
    case sourceMissing = "SOURCE_MISSING", sourceChanged = "SOURCE_CHANGED", destinationConflict = "DESTINATION_CONFLICT", invalidDestination = "INVALID_DESTINATION"
    case noSpace = "NO_SPACE", volumeUnavailable = "VOLUME_UNAVAILABLE", appUnavailable = "APP_UNAVAILABLE", automationDenied = "AUTOMATION_DENIED"
    case ioFailed = "IO_FAILED", metadataUnsupported = "METADATA_UNSUPPORTED", sourceRetained = "SOURCE_RETAINED", recoveryRequired = "RECOVERY_REQUIRED", cancelled = "CANCELLED"
}
public struct CommandFailure: Error, LocalizedError, Codable, Sendable, Equatable {
    public var code: CommandErrorCode
    public var message: String
    public var retryable: Bool
    public init(_ code: CommandErrorCode, _ message: String, retryable: Bool = false) { self.code = code; self.message = message; self.retryable = retryable }
    public var errorDescription: String? { message }
}
public enum ReceiptStatus: String, Codable, Sendable { case accepted, planning, waitingForUser, running, cancelling, completed, partial, failed, cancelled, needsReview, rejected }
public struct ItemReceipt: Codable, Sendable {
    public var itemID: UUID
    public var status: String
    public var destinationURL: URL?
    public var error: CommandFailure?
    public init(itemID: UUID = UUID(), status: String, destinationURL: URL? = nil, error: CommandFailure? = nil) { self.itemID = itemID; self.status = status; self.destinationURL = destinationURL; self.error = error }
    enum CodingKeys: String, CodingKey { case itemID, status, destinationURL, error }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(itemID, forKey: .itemID); try c.encode(status, forKey: .status)
        try c.encodeIfPresent(destinationURL, forKey: .destinationURL); try c.encode(error, forKey: .error)
    }
}
public struct CommandReceipt: Codable, Sendable {
    public var schemaVersion = 1
    public var requestID: UUID
    public var revision: Int
    public var status: ReceiptStatus
    public var updatedAt: Date
    public var itemResults: [ItemReceipt]
    public var error: CommandFailure?
    public init(requestID: UUID, revision: Int = 1, status: ReceiptStatus = .accepted, itemResults: [ItemReceipt] = [], error: CommandFailure? = nil) {
        self.requestID = requestID; self.revision = revision; self.status = status; updatedAt = Date(); self.itemResults = itemResults; self.error = error
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, requestID, revision, status, updatedAt, itemResults, error }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(requestID, forKey: .requestID); try c.encode(revision, forKey: .revision)
        try c.encode(status, forKey: .status); try c.encode(updatedAt, forKey: .updatedAt); try c.encode(itemResults, forKey: .itemResults); try c.encode(error, forKey: .error)
    }
}
public struct PendingMoveSnapshot: Codable, Sendable {
    public var token: UUID
    public var count: Int
    public var expiresAt: Date
    public init(token: UUID, count: Int, expiresAt: Date) { self.token = token; self.count = count; self.expiresAt = expiresAt }
}

public enum WireCodec {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer(); let s = try c.decode(String.self)
            let f = ISO8601DateFormatter()
            if let date = f.date(from: s) { return date }
            f.formatOptions.insert(.withFractionalSeconds)
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid RFC3339 date")
        }
        return d
    }
}
