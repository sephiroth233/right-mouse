import Foundation
import CoreFoundation

public enum RequestValidator {
    public static let maximumBytes = 1_048_576
    public static func decode(_ data: Data) throws -> CommandRequest {
        guard data.count <= maximumBytes else { throw CommandFailure(.limitExceeded, "请求过大，请分批操作") }
        let raw = try JSONSerialization.jsonObject(with: data)
        let root = try object(raw, required: ["schemaVersion","requestID","producerInstanceID","createdAt","expiresAt","context","action"])
        guard let version = root["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else { throw CommandFailure(.unsupportedVersion, "不支持的协议版本") }
        try identifier(root["requestID"]); try identifier(root["producerInstanceID"])
        let context = try object(root["context"], required: ["invocationID","entryPoint","container","selection"])
        try identifier(context["invocationID"])
        guard let selection = context["selection"] as? [Any], selection.count <= 1024 else { throw CommandFailure(.limitExceeded, "一次最多处理 1024 个选中项") }
        if !(context["container"] is NSNull) { try reference(context["container"]) }
        for item in selection { try reference(item) }
        guard let action = root["action"] as? [String: Any], let type = action["type"] as? String else { throw invalid() }
        let required: Set<String>
        var optional: Set<String> = []
        switch type {
        case "createFile": required = ["type","templateID","destination"]; optional = ["name"]
        case "copyText": required = ["type","format"]
        case "stageMove": required = ["type"]
        case "pasteMove": required = ["type","pendingToken","destination","conflictPolicy"]
        case "transfer": required = ["type","mode","destination","conflictPolicy"]
        case "openFavorite": required = ["type","favoriteID"]
        case "openWith": required = ["type","integrationID","mode"]
        default: throw invalid()
        }
        _ = try object(action, required: required, optional: optional)
        if let destination = action["destination"], !(destination is NSNull) { try reference(destination) }
        for key in ["templateID","integrationID"] where action[key] != nil {
            guard let value = action[key] as? String, !value.isEmpty, value.count <= 256 else { throw invalid() }
        }
        if let name = action["name"] {
            guard let s = name as? String, !s.isEmpty, s.count <= 255, ![".",".."].contains(s), !s.contains("/"), !s.contains("\0") else { throw CommandFailure(.invalidDestination, "文件名必须是单个有效名称") }
        }
        for key in ["pendingToken","favoriteID"] where action[key] != nil { try identifier(action[key]) }
        let request: CommandRequest
        do { request = try WireCodec.decoder().decode(CommandRequest.self, from: data) }
        catch { throw CommandFailure(.invalidRequest, "请求字段、日期或动作不合法") }
        guard Set(request.context.selection.map(\.refID)).count == request.context.selection.count else { throw invalid() }
        switch request.action {
        case .stageMove, .transfer:
            guard !request.context.selection.isEmpty else { throw CommandFailure(.contextUnavailable, "请先选择文件") }
        case let .copyText(format):
            guard !request.context.selection.isEmpty || (request.context.container != nil && (format == .path || format == .shellPath)) else { throw CommandFailure(.contextUnavailable, "没有可复制的文件或目录") }
        default: break
        }
        return request
    }
    public static func validateFresh(_ request: CommandRequest, now: Date = Date()) throws {
        let interval = request.expiresAt.timeIntervalSince(request.createdAt)
        guard interval > 0, interval <= 120.01, request.createdAt.timeIntervalSince(now) <= 30, request.expiresAt > now else {
            throw CommandFailure(.requestExpired, "操作请求已过期，请重新从菜单选择")
        }
    }
    public static func dispatchID(from url: URL) throws -> UUID {
        guard url.scheme == "rightmouse", url.host == "dispatch", url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2, let id = UUID(uuidString: url.lastPathComponent) else { throw invalid() }
        return id
    }
    private static func object(_ value: Any?, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let d = value as? [String: Any], required.isSubset(of: Set(d.keys)), Set(d.keys).isSubset(of: required.union(optional)) else { throw invalid() }
        return d
    }
    private static func identifier(_ raw: Any?) throws {
        guard let string = raw as? String, string.count == 36, UUID(uuidString: string) != nil else { throw invalid() }
    }
    private static func reference(_ raw: Any?) throws {
        let d = try object(raw, required: ["refID","fileURL","kindHint"], optional: ["bookmarkToken"])
        try identifier(d["refID"])
        if let token = d["bookmarkToken"] { try identifier(token) }
        guard let s = d["fileURL"] as? String, s.count <= 16384, s.hasPrefix("file:///"),
              let u = URLComponents(string: s), u.scheme == "file", (u.host ?? "").isEmpty,
              u.query == nil, u.fragment == nil, !u.path.contains("\0"),
              s.replacingOccurrences(of: "%[0-9A-Fa-f]{2}", with: "", options: .regularExpression).contains("%") == false,
              let kind = d["kindHint"] as? String, FileKind(rawValue: kind) != nil else { throw invalid() }
    }
    private static func invalid() -> CommandFailure { CommandFailure(.invalidRequest, "请求结构不合法") }
}

public enum PathText {
    public static func format(_ urls: [URL], as format: CopyTextFormat) -> String {
        urls.map { url in
            switch format {
            case .path: return url.path
            case .name: return url.lastPathComponent
            case .stem:
                let name = url.lastPathComponent
                if name.hasPrefix(".") && !name.dropFirst().contains(".") { return name }
                return (name as NSString).deletingPathExtension
            case .shellPath: return shellQuote(url.path)
            }
        }.joined(separator: "\n")
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func directory(for context: ActionContext) -> URL? {
        if context.selection.isEmpty { return context.container?.url }
        if context.selection.count == 1 {
            let item = context.selection[0]
            return item.kindHint == .directory ? item.url : item.url.deletingLastPathComponent()
        }
        let parents = Set(context.selection.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? parents.first : nil
    }
}
