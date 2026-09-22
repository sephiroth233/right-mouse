import AppKit
import RightMouseCore

@MainActor enum ApplicationLauncher {
    static func open(_ urls: [URL], with integration: AppIntegration) async throws {
        let application: URL?
        if let path = integration.applicationPath, FileManager.default.fileExists(atPath: path), Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == integration.bundleID { application = URL(fileURLWithPath: path) }
        else { application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: integration.bundleID) }
        guard let application else { throw CommandFailure(.appUnavailable, "未找到 \(integration.name)，请安装应用或重新选择打开方式。") }
        if integration.adapterType == "terminal" {
            guard integration.bundleID == "com.apple.Terminal" else { throw CommandFailure(.appUnavailable, "终端适配器仅支持 Apple Terminal，请为其他应用选择普通打开方式。") }
            guard let directory = urls.first else { throw CommandFailure(.contextUnavailable, "请选择工作目录") }
            // The path is a single shell argument; AppleScript receives a separately escaped literal.
            let shell = "cd -- " + PathText.shellQuote(directory.path)
            let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
            let source = "tell application id \"com.apple.Terminal\"\nactivate\ndo script \"\(literal)\"\nend tell"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int
                throw CommandFailure(code == -1743 ? .automationDenied : .ioFailed, code == -1743 ? "终端自动化权限被拒绝，请在系统设置的自动化中允许 RightMouse。" : "无法在终端打开目录（错误 \(code ?? 0)）。")
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
