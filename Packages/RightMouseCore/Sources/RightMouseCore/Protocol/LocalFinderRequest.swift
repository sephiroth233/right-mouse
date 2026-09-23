import Foundation

/// A deliberately narrow transport for unsigned, local-only Finder builds.
/// The caller supplies its build-time bundle mode flag; URL input can never enable it.
public enum LocalFinderRequest {
    public static let maximumURLBytes = 48 * 1024
    public static let maximumSelectionCount = 128
    public static let allowedTemplateIDs: Set<String> = ["txt", "md", "json", "sh"]
    public static let allowedIntegrationIDs: Set<String> = ["terminal", "vscode"]

    public static func encode(_ request: CommandRequest, localModeEnabled: Bool) throws -> URL {
        guard localModeEnabled else { throw failure("当前构建未启用本机 Finder 请求。") }
        try validate(request)
        let data = try WireCodec.encoder().encode(request)
        let payload = base64URLEncode(data)
        guard let url = URL(string: "rightmouse://local-action?payload=\(payload)"),
              url.absoluteString.utf8.count <= maximumURLBytes else { throw failure("本机请求 URL 过长。") }
        return url
    }

    public static func decode(_ url: URL, localModeEnabled: Bool, now: Date = Date()) throws -> CommandRequest {
        guard localModeEnabled else { throw failure("当前构建未启用本机 Finder 请求。") }
        guard url.absoluteString.utf8.count <= maximumURLBytes,
              url.scheme == "rightmouse", url.host == "local-action",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.fragment == nil,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              query.hasPrefix("payload="), !query.contains("&"), !query.contains(";"),
              query.filter({ $0 == "=" }).count == 1 else { throw failure("本机请求 URL 结构不合法。") }
        let payload = String(query.dropFirst("payload=".count))
        guard !payload.isEmpty, payload.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
        }), let data = base64URLDecode(payload), base64URLEncode(data) == payload else {
            throw failure("本机请求 payload 不是规范 base64url。")
        }
        let request = try RequestValidator.decode(data)
        guard try WireCodec.encoder().encode(request) == data else { throw failure("本机请求 payload 不是规范命令编码。") }
        try RequestValidator.validateFresh(request, now: now)
        try validate(request)
        return request
    }

    private static func validate(_ request: CommandRequest) throws {
        guard request.context.selection.count <= maximumSelectionCount else { throw failure("本机请求最多包含 128 个选中项。") }
        var references = request.context.selection
        if let container = request.context.container { references.append(container) }
        switch request.action {
        case let .createFile(templateID, destination, _):
            guard allowedTemplateIDs.contains(templateID) else { throw failure("本机请求不允许该模板。") }
            if let destination { references.append(destination) }
        case .copyText, .stageMove:
            break
        case let .transfer(_, destination, policy):
            guard destination == nil, policy == .ask else { throw failure("本机传输必须由宿主确认目标和冲突。") }
        case let .openWith(integrationID, _):
            guard allowedIntegrationIDs.contains(integrationID) else { throw failure("本机请求不允许该打开方式。") }
        case .pasteMove, .openFavorite:
            throw failure("本机请求不支持该动作。")
        }
        guard references.allSatisfy({ $0.bookmarkToken == nil }) else { throw failure("本机请求不得携带书签令牌。") }
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard, options: [])
    }

    private static func failure(_ message: String) -> CommandFailure { CommandFailure(.invalidRequest, message) }
}
