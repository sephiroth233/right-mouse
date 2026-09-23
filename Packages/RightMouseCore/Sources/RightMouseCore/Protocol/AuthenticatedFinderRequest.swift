import Foundation

/// Full commands are accepted only behind the signature-gated XPC listener.
/// The external URL codec deliberately remains a separate, narrower interface.
public enum AuthenticatedFinderRequest {
    public static let maximumBytes = 48 * 1024
    public static func encode(_ request: CommandRequest) throws -> Data {
        let data = try WireCodec.encoder().encode(request)
        _ = try decode(data)
        return data
    }
    public static func decode(_ data: Data, now: Date = Date()) throws -> CommandRequest {
        guard data.count <= maximumBytes else { throw CommandFailure(.invalidRequest, "Finder 请求过大。") }
        let request = try RequestValidator.decode(data)
        try RequestValidator.validateFresh(request, now: now)
        guard request.context.selection.count <= LocalFinderRequest.maximumSelectionCount else {
            throw CommandFailure(.invalidRequest, "Finder 请求最多包含 128 个选中项。")
        }
        return request
    }

    /// Validate the intent against current host configuration, never a cached
    /// extension snapshot. Bookmark tokens identify saved favorites, not grants.
    public static func validate(_ request: CommandRequest, configuration: AppConfiguration, pending: PendingMoveSnapshot?) throws {
        func reject() -> CommandFailure { CommandFailure(.invalidRequest, "菜单项目或目标已改变，请重新打开 Finder 右键菜单。") }
        let command: String
        switch request.action {
        case .transfer(let mode, _, _): command = mode == .copy ? "copyTo" : "moveTo"
        default: command = request.action.type
        }
        guard configuration.actions.contains(where: { $0.commandType == command && $0.enabled }),
              request.context.selection.allSatisfy({ $0.bookmarkToken == nil }),
              request.context.container?.bookmarkToken == nil else { throw reject() }
        func contextTarget(_ target: FileReference?) throws {
            guard let target else { return }
            guard target.bookmarkToken == nil, let container = request.context.container,
                  target.url == container.url, target.kindHint == container.kindHint else { throw reject() }
        }
        switch request.action {
        case let .createFile(id, target, _):
            guard configuration.templates.contains(where: { $0.id == id }) else { throw reject() }
            try contextTarget(target)
        case .copyText, .stageMove: break
        case let .pasteMove(token, target, policy):
            guard policy == .ask, pending?.token == token, (pending?.count ?? 0) > 0 else {
                throw CommandFailure(.requestExpired, "剪切列表已失效，请重新剪切文件。")
            }
            try contextTarget(target)
        case let .transfer(_, target, policy):
            guard policy == .ask else { throw reject() }
            if let target {
                guard let id = target.bookmarkToken, target.refID == id, target.kindHint == .directory,
                      let saved = configuration.favorites.first(where: { $0.id == id }),
                      target.url.standardizedFileURL.path == URL(fileURLWithPath: saved.path, isDirectory: true).standardizedFileURL.path else { throw reject() }
            }
        case let .openFavorite(id):
            guard configuration.favorites.contains(where: { $0.id == id }) else { throw reject() }
        case let .openWith(id, _):
            guard configuration.integrations.contains(where: { $0.id == id && $0.enabled }) else { throw reject() }
        }
    }
}

/// Only display metadata crosses into Finder. Pending state is never persisted
/// in the extension cache and is invalidated by clipboard changes/disconnection.
public struct LocalFinderMenuState: Codable, Sendable {
    public static let cacheKey = "RightMouseAuthenticatedMenu.v1"
    public let configuration: MenuConfigurationSnapshot
    public let pendingMove: PendingMoveSnapshot?
    public let pasteboardChangeCount: Int
    public init(configuration: MenuConfigurationSnapshot, pendingMove: PendingMoveSnapshot?, pasteboardChangeCount: Int) {
        self.configuration = configuration; self.pendingMove = pendingMove
        self.pasteboardChangeCount = pasteboardChangeCount
    }
    public func encoded() throws -> Data {
        let data = try WireCodec.encoder().encode(self)
        _ = try Self.decode(data)
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= MenuSnapshotStore.maximumBytes else { throw ConfigurationError.invalid("菜单状态过大。") }
        let state = try WireCodec.decoder().decode(Self.self, from: data)
        try state.configuration.validate()
        if let pending = state.pendingMove {
            guard (1...128).contains(pending.count) else { throw ConfigurationError.invalid("剪切摘要无效。") }
        }
        return state
    }
}
