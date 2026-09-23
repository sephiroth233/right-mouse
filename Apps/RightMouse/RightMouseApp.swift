import SwiftUI
import AppKit
import RightMouseCore
import Carbon
import OSLog
import Combine

@main
enum RightMouseApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        // Start as an agent to avoid a Dock flash during login/Finder wake.
        // Explicitly opening a window promotes the process to a regular app.
        if let icon = AppIcons.brand { app.applicationIconImage = icon }
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controller: HostController?
    private var localXPC: LocalXPCController?
    private var settingsWindow: NSWindow?
    private var tasksWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var receivedDispatch = false
    private var launchPolicy = ApplicationLaunchPolicy()
    private var initialLaunchFinished = false
    private var startupURLs: [URL] = []
    private var localLayoutSubscription: AnyCancellable?
    private var errorSubscription: AnyCancellable?
    private var statusItemSubscription: AnyCancellable?
    private let logger = Logger(subsystem: "cn.rightmouse.RightMouse", category: "URLDispatch")
    func applicationWillFinishLaunching(_ notification: Notification) {
        launchPolicy.observe(NSAppleEventManager.shared().currentAppleEvent)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              value.utf8.count <= LocalFinderRequest.maximumURLBytes, let url = URL(string: value) else { return }
        application(NSApplication.shared, open: [url])
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchPolicy.observe(NSAppleEventManager.shared().currentAppleEvent)
        installMenu()
        do {
            controller = try HostController()
            if Bundle.main.object(forInfoDictionaryKey: "RightMouseLocalFinderMode") as? Bool == true, let controller {
                DistributedNotificationCenter.default().addObserver(self, selector: #selector(sendLocalLayout), name: LocalMenuLayout.requested, object: nil, suspensionBehavior: .deliverImmediately)
                localLayoutSubscription = controller.model.$configuration.sink { configuration in
                    Self.publishLocalLayout(configuration)
                }
            }
            errorSubscription = controller?.model.$errorMessage.compactMap { $0 }.sink { [weak self] message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let model = self.controller?.model, model.errorMessage == message else { return }
                    if self.launchPolicy.startsInBackground && !self.initialLaunchFinished {
                        model.notice = message; model.errorMessage = nil
                        return
                    }
                    model.errorMessage = nil
                    let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = message
                    alert.addButton(withTitle: "好")
                    NSApp.activate(ignoringOtherApps: true); alert.runModal()
                }
            }
            controller?.showTasks = { [weak self] in self?.showTasks() }
            controller?.scanInbox()
            if let controller, let identity = LocalXPCIdentity() {
                localXPC = LocalXPCController(identity: identity, controller: controller)
                localXPC?.start()
            }
            statusItemSubscription = controller?.model.$configuration
                .map(\.showMenuBarIcon).removeDuplicates()
                .sink { [weak self] visible in self?.updateStatusItem(visible: visible) }
            let waiting = startupURLs; startupURLs.removeAll()
            if !waiting.isEmpty { self.application(NSApplication.shared, open: waiting) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.initialLaunchFinished = true
                guard self.launchPolicy.shouldPresentInitialWindow(receivedDispatch: self.receivedDispatch) else { return }
                self.showSettings()
            }
        } catch {
            if launchPolicy.startsInBackground {
                logger.error("Background startup failed: \(error.localizedDescription, privacy: .private)")
                NSApp.terminate(nil); return
            }
            let alert = NSAlert(); alert.messageText = "RightMouse 无法启动"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.notice("Received URL event, count: \(urls.count)")
        guard let controller else { startupURLs.append(contentsOf: urls.prefix(max(0, 8 - startupURLs.count))); return }
        for url in urls {
            if url.scheme == "rightmouse", url.host == "wake", url.query == nil, url.fragment == nil { receivedDispatch = true; continue }
            if url.scheme == "rightmouse", url.host == "settings", url.query == nil, url.fragment == nil { showSettings(); continue }
            receivedDispatch = true
            if url.host == "local-action" { controller.receiveLocalFinderURL(url); continue }
            do {
                let id = try RequestValidator.dispatchID(from: url)
                controller.receive(id)
            } catch { controller.model.reportError(error) }
        }
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchPolicy.observe(NSAppleEventManager.shared().currentAppleEvent)
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if ApplicationLaunchPolicy.isLoginEvent(event) { return false }
        showSettings(); return true
    }
    func windowWillClose(_ notification: Notification) {
        // willClose precedes the window actually disappearing. Recheck on the next
        // run-loop turn so closing one of two windows never hides the other one.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hasWindow = [self.settingsWindow, self.tasksWindow].compactMap { $0 }
                .contains { $0.isVisible || $0.isMiniaturized }
            if !hasWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
    private func updateStatusItem(visible: Bool) {
        guard visible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "RightMouse")
        item.button?.toolTip = "RightMouse"
        let menu = NSMenu()
        menu.addItem(withTitle: "RightMouse 设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 RightMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu; statusItem = item
    }
    private func prepareForWindowPresentation() {
        launchPolicy.didPresentWindow()
        NSApp.setActivationPolicy(.regular)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func sendLocalLayout() {
        if let controller { Self.publishLocalLayout(controller.model.configuration) }
    }
    private static func publishLocalLayout(_ configuration: AppConfiguration) {
        guard let payload = try? LocalMenuLayout(configuration: configuration).encoded() else { return }
        DistributedNotificationCenter.default().postNotificationName(LocalMenuLayout.changed, object: payload, userInfo: nil, deliverImmediately: true)
    }
    @objc private func showSettings() {
        guard let controller else { return }
        prepareForWindowPresentation()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowLayout.settingsSize), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "RightMouse"; window.isReleasedWhenClosed = false; window.isRestorable = false; window.delegate = self
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
        prepareForWindowPresentation()
        if tasksWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "RightMouse 文件核对"; window.isReleasedWhenClosed = false; window.isRestorable = false; window.delegate = self
            let hosting = NSHostingController(rootView: TasksView(model: controller.model).padding(.top, 20).background(RightMouseBackdrop()).groupBoxStyle(RightMouseGroupBoxStyle()))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            WindowLayout.prepare(window, preferred: WindowLayout.tasksSize, minimum: NSSize(width: 600, height: 420))
            tasksWindow = window
        }
        if let tasksWindow { WindowLayout.centerForReopen(tasksWindow) }
        tasksWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
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
