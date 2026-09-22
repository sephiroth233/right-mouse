import AppKit
import RightMouseCore

typealias ProjectDirectoryPicker = @MainActor () -> URL?
typealias ApplicationOpen = @MainActor ([URL], AppIntegration) async throws -> Void

@MainActor enum OpenWithInteraction {
    static func chooseProjectDirectory() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "所选项目来自多个位置，请选择一个 Visual Studio Code 项目目录。"
        panel.prompt = "打开项目"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
