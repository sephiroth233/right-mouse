import Foundation
import RightMouseCore

struct OpenWithItem: Equatable {
    let url: URL
    let isDirectory: Bool
}

enum OpenWithPlan: Equatable {
    case launch([URL])
    case chooseProjectDirectory
}

enum OpenWithPlanning {
    static func plan(items: [OpenWithItem], adapterType: String) throws -> OpenWithPlan {
        guard !items.isEmpty else { throw CommandFailure(.contextUnavailable, "请选择要打开的文件或目录") }
        guard items.allSatisfy({ $0.url.isFileURL }) else { throw CommandFailure(.invalidRequest, "打开方式只接受本地文件或目录") }
        if adapterType == "terminal", let first = items.first {
            let directory = first.isDirectory ? first.url : first.url.deletingLastPathComponent()
            return .launch([directory.standardizedFileURL])
        }
        guard adapterType == "vscode" else { return .launch(items.map(\.url)) }
        if items.count == 1 { return .launch([items[0].url]) }
        if items.contains(where: \.isDirectory) { return .chooseProjectDirectory }
        let parents = Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? .launch(items.map(\.url)) : .chooseProjectDirectory
    }

    static func validateAdapter(_ integration: AppIntegration, applicationBundleID: String?) throws {
        guard applicationBundleID == integration.bundleID else {
            throw CommandFailure(.appUnavailable, "所选应用与打开方式配置不匹配，请重新选择应用。")
        }
        switch integration.adapterType {
        case "terminal":
            guard integration.bundleID == "com.apple.Terminal" else {
                throw CommandFailure(.appUnavailable, "终端适配器仅支持 Apple Terminal，请为其他应用选择普通打开方式。")
            }
        case "vscode":
            guard integration.bundleID == "com.microsoft.VSCode" else {
                throw CommandFailure(.appUnavailable, "Visual Studio Code 适配器与应用不匹配，请重新选择打开方式。")
            }
        case "urls": break
        default: throw CommandFailure(.appUnavailable, "此应用的打开能力未经支持，请改用普通 URL 打开方式。")
        }
    }
}
