import AppKit
import FinderSync
import Foundation
import OSLog
import RightMouseCore

/// Each menu item retains its own invocation. A later Finder menu cannot change it.
private final class MenuInvocation: NSObject {
    let context: ActionContext
    let action: CommandAction
    init(context: ActionContext, action: CommandAction) { self.context = context; self.action = action }
}

final class FinderSync: FIFinderSync {
    private let producerID = UUID()
    private let ioQueue = DispatchQueue(label: "cn.rightmouse.finder.configuration", qos: .utility)
    private let logger = Logger(subsystem: "cn.rightmouse.RightMouse.FinderExtension", category: "Finder")
    private var configuration = MenuConfigurationSnapshot(configuration: AppConfiguration(), available: false)
    private var pendingMove: PendingMoveSnapshot?
    private var paths: SharedPaths?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var refreshTimer: DispatchSourceTimer?
    private var configurationError = false
    private var localClient: LocalXPCClient?
    private let localMode = Bundle.main.object(forInfoDictionaryKey: "RightMouseLocalFinderMode") as? Bool == true
    private var invocations: [Int: (value: MenuInvocation, expires: Date)] = [:]
    private var nextInvocationTag = 1
    private var applicationIcons: [String: NSImage] = [:]
    private let brandIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))

    override init() {
        super.init()
        // Resolve installed application artwork once, away from menu callbacks.
        ioQueue.async { [weak self] in
            var icons: [String: NSImage] = [:]
            for (id, bundleID) in [("terminal", "com.apple.Terminal"), ("vscode", "com.microsoft.VSCode")] {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 16, height: 16); icons[id] = icon
                }
            }
            let loaded = icons
            DispatchQueue.main.async { self?.applicationIcons = loaded }
        }
        if localMode {
            let cached = UserDefaults.standard.string(forKey: LocalMenuLayout.cacheKey)
                .flatMap { try? LocalMenuLayout.decode($0) }
            configuration = MenuConfigurationSnapshot(configuration: cached?.configuration ?? LocalMenuLayout.baseConfiguration)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveLocalLayout(_:)), name: LocalMenuLayout.changed, object: nil, suspensionBehavior: .deliverImmediately)
            requestLocalLayout()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.requestLocalLayout() }
            timer.resume(); refreshTimer = timer
            refreshLocalScope()
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshLocalScope), name: name, object: nil)
            }
            logger.notice("Local Finder mode initialized without shared storage")
            return
        }
        // Empty until the host has explicitly configured monitored locations.
        FIFinderSyncController.default().directoryURLs = []
        ioQueue.async { [weak self] in self?.initializeStorage() }
    }

    deinit { sources.forEach { $0.cancel() }; refreshTimer?.cancel(); NSWorkspace.shared.notificationCenter.removeObserver(self); DistributedNotificationCenter.default().removeObserver(self) }

    private func requestLocalLayout() {
        DistributedNotificationCenter.default().postNotificationName(LocalMenuLayout.requested, object: nil, userInfo: nil, deliverImmediately: true)
    }
    @objc private func receiveLocalLayout(_ notification: Notification) {
        guard localMode, let payload = notification.object as? String,
              let layout = try? LocalMenuLayout.decode(payload) else { return }
        // Only fixed built-in IDs and two presentation preferences cross this
        // unauthenticated channel. It cannot authorize operations; those require
        // authenticated XPC or the legacy URL confirmation.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let snapshot = MenuConfigurationSnapshot(configuration: layout.configuration)
            guard self.configuration != snapshot else { return }
            self.configuration = snapshot
            UserDefaults.standard.set(payload, forKey: LocalMenuLayout.cacheKey)
            self.logger.notice("Local menu layout updated; top-level count: \(layout.topLevelEntryIDs.count)")
        }
    }

    @objc private func refreshLocalScope() {
        // Monitoring affects Finder UI only. It grants no filesystem access.
        // Include the Data volume explicitly because monitoring does not cross volumes.
        var roots: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true), URL(fileURLWithPath: "/Users", isDirectory: true), URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)]
        roots.formUnion(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
        FIFinderSyncController.default().directoryURLs = roots
    }

    private func initializeStorage() {
        do {
            let resolved = try SharedPaths.resolve()
            DispatchQueue.main.async { [weak self] in self?.paths = resolved }
            refresh(paths: resolved)
            watch(resolved.menuDirectory, paths: resolved)
            watch(resolved.root, paths: resolved)
            // Notifications can be lost when directories are atomically replaced. A small
            // bounded read also refreshes the clipboard snapshot after host cold starts.
            let timer = DispatchSource.makeTimerSource(queue: ioQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.refresh(paths: resolved) }
            timer.resume(); refreshTimer = timer
        } catch {
            logger.error("Shared storage unavailable")
            DispatchQueue.main.async { [weak self] in self?.configurationError = true }
        }
    }

    private func watch(_ directory: URL, paths: SharedPaths) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: ioQueue)
        source.setEventHandler { [weak self] in self?.refresh(paths: paths) }
        source.setCancelHandler { close(fd) }
        source.resume(); sources.append(source)
    }

    private func refresh(paths: SharedPaths) {
        do {
            // Only the host publishes this authority-free menu projection. Never
            // read a legacy full configuration or a host-private storage location.
            let config = try MenuSnapshotStore(directory: paths.menuDirectory).load()
            let pending: PendingMoveSnapshot?
            if let data = try? PrivateFileIO.read(paths.pendingMoveURL, maximumBytes: 4096) {
                pending = try? WireCodec.decoder().decode(PendingMoveSnapshot.self, from: data)
            } else { pending = nil }
            // Paths identify monitored UI scope only; they grant no read/write authority.
            let watched = Set(config.watchedLocations.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configuration = config; self.pendingMove = pending; self.configurationError = !config.available
                FIFinderSyncController.default().directoryURLs = watched
            }
        } catch {
            logger.error("Configuration refresh rejected")
            DispatchQueue.main.async { [weak self] in self?.configurationError = true }
        }
    }

    override var toolbarItemName: String { "RightMouse" }
    override var toolbarItemToolTip: String { "RightMouse 文件操作与设置" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "RightMouse") ?? NSImage(size: NSSize(width: 18, height: 18)) }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        invocations = invocations.filter { $0.value.expires > Date() }
        if invocations.count > 4096 { invocations.removeAll() }
        let start = ContinuousClock.now
        let controller = FIFinderSyncController.default()
        let entryPoint: EntryPoint
        switch menuKind {
        case .contextualMenuForItems: entryPoint = .items
        case .contextualMenuForContainer: entryPoint = .container
        case .contextualMenuForSidebar: entryPoint = .sidebar
        default: entryPoint = .toolbar
        }
        // Capture Finder values synchronously during the documented callback lifetime.
        let target = controller.targetedURL()
        let urls: [URL]
        if entryPoint == .container { urls = [] }
        else if entryPoint == .sidebar { urls = target.map { [$0] } ?? [] }
        else { urls = controller.selectedItemURLs() ?? [] }
        // The host resolves real object kinds at execution time. A trailing slash
        // is not reliable evidence that a Finder URL denotes a directory.
        let container = target.map { FileReference(url: $0, kindHint: entryPoint == .container ? .directory : .unknown) }
        let context = ActionContext(entryPoint: entryPoint, container: container, selection: urls.map { FileReference(url: $0, kindHint: .unknown) })
        let menu = NSMenu(title: "RightMouse"); menu.autoenablesItems = false
        if configurationError {
            let message = NSMenuItem(title: "RightMouse 配置或共享目录不可用", action: nil, keyEquivalent: "")
            message.isEnabled = false; menu.addItem(message)
        }
        if (paths != nil || localMode), !configurationError {
            for entry in MenuPolicy.entries(snapshot: configuration, context: context, pendingMove: pendingMove) { menu.addItem(makeItem(entry, context: context)) }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let settings = NSMenuItem(title: "RightMouse 设置…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.image = symbol("gearshape")
        settings.target = self; menu.addItem(settings)
        let elapsed = start.duration(to: .now)
        logger.debug("Built menu in \(String(describing: elapsed), privacy: .public)")
        return menu
    }

    private func makeItem(_ entry: MenuEntry, context: ActionContext) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: entry.action == nil ? nil : #selector(dispatch(_:)), keyEquivalent: "")
        if entry.id == "rightmouse", let brand = brandIcon?.copy() as? NSImage {
            brand.size = NSSize(width: 18, height: 18); item.image = brand
        } else if case let .openWith(id, _) = entry.action, let icon = applicationIcons[id] { item.image = icon }
        else { item.image = symbol(MenuIcon.symbol(for: entry)) }
        item.isEnabled = entry.enabled && (!localMode || context.selection.count <= 128); item.target = self
        if let action = entry.action {
            let invocation = MenuInvocation(context: context, action: action)
            item.representedObject = invocation
            // Finder serializes menu items across its process boundary. Preserve
            // context in the extension, using the standard integer tag as the key.
            item.tag = nextInvocationTag; nextInvocationTag += 1
            invocations[item.tag] = (invocation, Date().addingTimeInterval(120))
        }
        if !entry.children.isEmpty {
            let submenu = NSMenu(title: entry.title); submenu.autoenablesItems = false
            entry.children.forEach { submenu.addItem(makeItem($0, context: context)) }; item.submenu = submenu
        }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16); image?.isTemplate = true
        return image
    }

    @objc private func dispatch(_ sender: NSMenuItem) {
        logger.notice("Finder menu action received")
        guard let stored = invocations[sender.tag], stored.expires > Date() else {
            logger.error("Finder menu invocation expired or missing"); NSSound.beep(); return
        }
        let invocation = stored.value
        let request = CommandRequest(context: invocation.context, action: invocation.action, producerInstanceID: producerID)
        if localMode {
            do {
                _ = try RequestValidator.decode(WireCodec.encoder().encode(request))
                let url = try LocalFinderRequest.encode(request, localModeEnabled: localMode)
                if case let .copyText(format) = request.action {
                    let urls = invocation.context.selection.isEmpty ? [invocation.context.container!.url] : invocation.context.selection.map(\.url)
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(PathText.format(urls, as: format), forType: .string) else { throw CommandFailure(.ioFailed, "无法写入剪贴板") }
                } else if let identity = LocalXPCIdentity() {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.localClient == nil { self.localClient = LocalXPCClient(identity: identity) }
                        self.localClient?.send(request, wakeHost: { [weak self] in self?.openHost(dispatchURL: URL(string: "rightmouse://wake")) }, failure: { [weak self] in
                            self?.logger.error("Authenticated Finder request unavailable; check tasks before retrying")
                            NSSound.beep(); self?.openHost(dispatchURL: nil)
                        })
                    }
                } else { openHost(dispatchURL: url) }
            } catch {
                logger.error("Local request rejected: \(error.localizedDescription, privacy: .public)")
                NSSound.beep(); openHost(dispatchURL: nil)
            }
            return
        }
        guard let paths else { return }
        ioQueue.async { [weak self] in
            do {
                try InboxStore(directory: paths.inboxDirectory).enqueue(request)
                guard let url = URL(string: "rightmouse://dispatch/\(request.requestID.uuidString)") else { return }
                DispatchQueue.main.async { [weak self] in self?.openHost(dispatchURL: url) }
            } catch {
                self?.logger.error("Request could not be queued: \(request.requestID.uuidString, privacy: .public)")
                DispatchQueue.main.async { [weak self] in self?.openHost(dispatchURL: nil) }
            }
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) { openHost(dispatchURL: nil) }

    private func openHost(dispatchURL: URL?) {
        let plugins = Bundle.main.bundleURL.deletingLastPathComponent()
        let contents = plugins.deletingLastPathComponent()
        let host = contents.deletingLastPathComponent()
        // The extension sandbox cannot read the enclosing app's Info.plist.
        // Derive the exact containing app from our own bundle, never URL input;
        // let Launch Services open it without probing host-private bundle files.
        guard Bundle.main.bundleIdentifier == "cn.rightmouse.RightMouse.FinderExtension",
              plugins.lastPathComponent == "PlugIns", contents.lastPathComponent == "Contents", host.pathExtension == "app" else {
            logger.error("Embedding host layout mismatch"); return
        }
        let options = NSWorkspace.OpenConfiguration(); options.activates = dispatchURL?.host == "wake" ? false : (localMode || dispatchURL == nil)
        if dispatchURL?.host == "wake" { options.arguments = ["--finder-wake"] }
        if let dispatchURL {
            NSWorkspace.shared.open([dispatchURL], withApplicationAt: host, configuration: options) { [weak self] _, error in
                if error != nil { self?.logger.error("Host wake failed; queued request retained") }
            }
        } else {
            NSWorkspace.shared.openApplication(at: host, configuration: options) { [weak self] _, error in
                if error != nil { self?.logger.error("Host launch failed") }
            }
        }
    }
}
