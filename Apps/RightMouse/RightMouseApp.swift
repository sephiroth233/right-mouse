import SwiftUI
import AppKit
import RightMouseCore

@main
enum RightMouseApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: HostController?
    private var settingsWindow: NSWindow?
    private var tasksWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var receivedDispatch = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        do {
            controller = try HostController()
            controller?.showTasks = { [weak self] in self?.showTasks() }
            controller?.scanInbox()
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "RightMouse")
            let menu = NSMenu()
            menu.addItem(withTitle: "RightMouse 设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(withTitle: "文件任务", action: #selector(showTasks), keyEquivalent: "").target = self
            menu.addItem(.separator()); menu.addItem(withTitle: "退出 RightMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu; statusItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.receivedDispatch else { return }
                self.showSettings()
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "RightMouse 无法启动"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "rightmouse", url.host == "settings", url.query == nil, url.fragment == nil { showSettings(); continue }
            receivedDispatch = true
            do {
                let id = try RequestValidator.dispatchID(from: url)
                if let controller { controller.receive(id) }
                else { DispatchQueue.main.async { [weak self] in self?.controller?.receive(id) } }
            } catch { controller?.model.reportError(error) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func showSettings() {
        guard let controller else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowLayout.settingsSize), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "RightMouse"; window.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: RootView(model: controller.model))
            // WindowLayout owns window bounds. Page-specific intrinsic sizes must
            // not change contentMinSize/contentMaxSize when the sidebar changes.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            WindowLayout.prepare(window, preferred: WindowLayout.settingsSize, minimum: WindowLayout.minimumSettingsSize)
            settingsWindow = window
        }
        if let settingsWindow { WindowLayout.centerForReopen(settingsWindow) }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showTasks() {
        guard let controller else { return }
        if tasksWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "RightMouse 文件任务"; window.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: TasksView(model: controller.model).padding(.top, 20).background(RightMouseBackdrop()).groupBoxStyle(RightMouseGroupBoxStyle()))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            WindowLayout.prepare(window, preferred: WindowLayout.tasksSize, minimum: NSSize(width: 600, height: 420))
            tasksWindow = window
        }
        if let tasksWindow { WindowLayout.centerForReopen(tasksWindow) }
        tasksWindow?.makeKeyAndOrderFront(nil)
    }
    private func installMenu() {
        let main = NSMenu(); let application = NSMenuItem(); main.addItem(application)
        let menu = NSMenu(); application.submenu = menu
        menu.addItem(withTitle: "关于 RightMouse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "退出 RightMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); main.addItem(edit); let editMenu = NSMenu(title: "编辑"); edit.submenu = editMenu
        for (title, action, key) in [("撤销", "undo:", "z"),("剪切", "cut:", "x"),("复制", "copy:", "c"),("粘贴", "paste:", "v"),("全选", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        NSApp.mainMenu = main
    }
}
