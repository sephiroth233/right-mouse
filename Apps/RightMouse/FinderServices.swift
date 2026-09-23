import AppKit
import RightMouseCore

/// Services carries file URLs through the system pasteboard, independently of
/// Finder Sync's directory coverage. Never interpret service data as a command.
enum FinderServiceAction: String, CaseIterable {
    case createTXT, createMarkdown, copyPath, openTerminal, openVSCode
}

enum FinderServiceRequest {
    static let maximumItems = 128
    static let maximumBytes = 64 * 1024

    static func urls(from pasteboard: NSPasteboard) throws -> [URL] {
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= maximumItems else { throw invalid("一次最多处理 128 项。") }
        // Validate an advertised legacy list before AppKit's automatic conversion
        // can turn a relative filename into an apparently absolute file URL.
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        var legacyPaths: [String]?
        if let data = pasteboard.data(forType: legacy) {
            guard data.count <= maximumBytes,
                  let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
                  paths.count <= maximumItems, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
                throw invalid("服务收到的文件列表无效。")
            }
            legacyPaths = paths
        }
        if items.contains(where: { $0.types.contains(.fileURL) }) {
            var size = 0
            return try items.map { item in
                guard let data = item.data(forType: .fileURL) else { throw invalid("服务需要文件或文件夹，不能混入其他内容。") }
                size += data.count
                guard size <= maximumBytes, let value = String(data: data, encoding: .utf8),
                      let url = URL(string: value) else { throw invalid("文件地址无效或过长。") }
                return url
            }
        }
        // Finder also advertises the legacy file-list flavor on some systems.
        guard let paths = legacyPaths else {
            throw invalid("没有收到有效的文件或文件夹，请从 Finder 的服务菜单重试。")
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func make(action raw: String?, urls: [URL], configuration: AppConfiguration) throws -> CommandRequest {
        guard let raw, let action = FinderServiceAction(rawValue: raw) else { throw invalid("未知的 RightMouse 服务。") }
        guard !urls.isEmpty, urls.count <= maximumItems,
              urls.reduce(0, { $0 + $1.absoluteString.utf8.count }) <= maximumBytes,
              urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && $0.query == nil && $0.fragment == nil && $0.user == nil && $0.password == nil && $0.port == nil && !$0.path.contains("\0") }) else {
            throw invalid("服务只接受 1–128 个有效的本地文件或文件夹地址。")
        }
        let selection = urls.map { FileReference(url: $0, kindHint: .unknown) }
        var context = ActionContext(entryPoint: .items, container: nil, selection: selection)
        let command: CommandAction
        let group: String
        switch action {
        case .createTXT, .createMarkdown:
            group = "createFile"
            let templateID = action == .createTXT ? "txt" : "md"
            guard configuration.templates.contains(where: { $0.id == templateID }) else { throw invalid("对应模板已移除，请在新建文件设置中恢复。") }
            guard urls.count == 1, try urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw invalid("请选择一个文件夹，或在目标文件夹的空白处使用新建服务。")
            }
            let directory = FileReference(url: urls[0], kindHint: .directory)
            context = ActionContext(entryPoint: .container, container: directory, selection: [])
            command = .createFile(templateID: templateID, destination: directory, name: nil)
        case .copyPath:
            group = "copyText"
            command = .copyText(format: .path)
        case .openTerminal, .openVSCode:
            group = "openWith"
            let integration = action == .openTerminal ? "terminal" : "vscode"
            guard configuration.integrations.contains(where: { $0.id == integration && $0.enabled }) else { throw invalid("对应打开方式已停用，请在应用设置中启用。") }
            if action == .openTerminal && urls.count != 1 { throw invalid("请只选择一个文件或文件夹再打开终端。") }
            command = .openWith(integrationID: integration, mode: action == .openTerminal ? .directory : .files)
        }
        guard configuration.actions.contains(where: { $0.id == group && $0.enabled }) else { throw invalid("此操作已在 RightMouse 中停用。") }
        let request = CommandRequest(context: context, action: command)
        _ = try RequestValidator.decode(WireCodec.encoder().encode(request))
        return request
    }

    private static func invalid(_ message: String) -> CommandFailure { CommandFailure(.invalidRequest, message) }
}

@MainActor final class FinderServicesProvider: NSObject {
    var onInvocation: () -> Void = {}
    var configuration: () -> AppConfiguration? = { nil }
    var submit: (CommandRequest) -> Bool = { _ in false }

    @objc func performAction(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        onInvocation()
        do {
            guard let config = configuration() else { throw CommandFailure(.contextUnavailable, "RightMouse 尚未就绪，请稍后重试。") }
            let urls = try FinderServiceRequest.urls(from: pasteboard)
            let request = try FinderServiceRequest.make(action: userData, urls: urls, configuration: config)
            // The host owns asynchronous execution and its existing error UI.
            _ = submit(request)
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }
}
