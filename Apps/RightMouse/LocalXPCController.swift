import Foundation
import AppKit
import RightMouseCore
import OSLog

/// One authenticated connection carries one action after a harmless handshake.
final class FinderXPCSession: NSObject, LocalFinderService {
    private let lock = NSLock()
    private var handshaken = false
    private var consumed = false
    private let receive: (Data, @escaping (Bool) -> Void) -> Void
    private let readMenu: (@escaping (Data) -> Void) -> Void
    init(readMenu: @escaping (@escaping (Data) -> Void) -> Void = { $0(Data()) }, receive: @escaping (Data, @escaping (Bool) -> Void) -> Void) {
        self.readMenu = readMenu; self.receive = receive
    }
    func handshake(_ nonce: String, reply: @escaping (String) -> Void) {
        lock.lock()
        let valid = !consumed && !handshaken && LocalXPCIdentity.validNonce(nonce)
        if valid { handshaken = true }
        lock.unlock()
        reply(valid ? LocalXPCIdentity.response(nonce) : "")
    }
    func menuState(reply: @escaping (Data) -> Void) {
        lock.lock()
        let valid = handshaken && !consumed
        consumed = true
        lock.unlock()
        guard valid else { reply(Data()); return }
        readMenu(reply)
    }
    func perform(_ payload: Data, reply: @escaping (Bool) -> Void) {
        lock.lock()
        let valid = handshaken && !consumed && payload.count <= LocalFinderRequest.maximumURLBytes
        consumed = true
        lock.unlock()
        guard valid else { reply(false); return }
        receive(payload, reply)
    }
}

final class FinderXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    let receive: (Data, @escaping (Bool) -> Void) -> Void
    let readMenu: (@escaping (Data) -> Void) -> Void
    init(readMenu: @escaping (@escaping (Data) -> Void) -> Void, receive: @escaping (Data, @escaping (Bool) -> Void) -> Void) {
        self.readMenu = readMenu; self.receive = receive
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: LocalFinderService.self)
        connection.exportedObject = FinderXPCSession(readMenu: readMenu, receive: receive)
        connection.resume(); return true
    }
}

@MainActor final class LocalXPCController {
    private let identity: LocalXPCIdentity
    private let listener = NSXPCListener.anonymous()
    private let delegate: FinderXPCListenerDelegate
    private var registration: NSXPCConnection?
    private var timer: Timer?
    private weak var model: AppModel?
    private var stopped = false
    private var connecting = false
    private var generation = UUID()
    private let logger = Logger(subsystem: "cn.rightmouse.RightMouse", category: "LocalXPC")
    init(identity: LocalXPCIdentity, controller: HostController) {
        self.identity = identity; model = controller.model
        delegate = FinderXPCListenerDelegate(readMenu: { [weak controller] reply in
            Task { @MainActor in reply(controller?.authenticatedMenuState() ?? Data()) }
        }) { [weak controller] data, reply in
            Task { @MainActor in reply(controller?.receiveAuthenticatedFinderData(data) ?? false) }
        }
        listener.setConnectionCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse.FinderExtension"))
        listener.delegate = delegate; listener.resume()
        controller.model.authenticatedXPCBuild = true
        controller.model.storageDiagnostic = "本机连接服务通过身份校验连接 Finder 和主应用，不依赖 App Group。菜单配置与剪切状态自动同步，操作无需逐次确认来源；目录选择、访问授权和同名冲突仍会按需提示。"
        controller.model.onRepairLocalService = { [weak self] in self?.start(repair: true) }
        controller.model.onStopLocalService = { [weak self] in self?.stop() }
    }
    func start(repair: Bool = false) {
        stopped = false
        do {
            if repair { UserDefaults.standard.removeObject(forKey: "RightMouseLocalServiceDisabled") }
            if UserDefaults.standard.bool(forKey: "RightMouseLocalServiceDisabled") {
                model?.localServiceStatus = "本机连接服务已停用"; return
            }
            try LocalServiceInstaller.install(identity: identity, force: repair)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.connect() }
            }
            connect()
        } catch { model?.localServiceStatus = "本机连接服务不可用：\(error.localizedDescription)" }
    }
    private func connect() {
        guard !stopped, !connecting, registration == nil else { return }
        connecting = true
        let token = UUID(); generation = token
        let connection = NSXPCConnection(machServiceName: identity.registrationService)
        connection.remoteObjectInterface = NSXPCInterface(with: LocalBridgeRegistration.self)
        connection.setCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse.Bridge"))
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.registration = nil; self.connecting = false; self.model?.localServiceReady = false
                self.model?.localServiceStatus = self.stopped ? "本机连接服务已停用" : "正在重新连接本机服务…"
            }
        }
        connection.interruptionHandler = { connection.invalidate() }
        connection.resume(); registration = connection
        let endpoint = listener.endpoint
        Task { [weak self] in
            do {
                // An endpoint is a capability, but the listener independently pins
                // Finder's signature before accepting any message on that endpoint.
                let accepted: Bool = try await LocalXPCCall.invoke(connection) { proxy, reply in
                    (proxy as! LocalBridgeRegistration).registerHost(endpoint, reply: reply)
                }
                guard let self, self.generation == token, !self.stopped else { connection.invalidate(); return }
                guard accepted else { throw LocalXPCError.rejected }
                self.connecting = false; self.model?.localServiceReady = true
                self.model?.localServiceStatus = "本机连接已就绪，Finder 操作无需逐次确认来源。"
                self.logger.notice("Authenticated Finder endpoint registered")
            } catch { connection.invalidate() }
        }
    }
    func stop() {
        stopped = true; timer?.invalidate(); timer = nil
        registration?.invalidate(); registration = nil; connecting = false
        UserDefaults.standard.set(true, forKey: "RightMouseLocalServiceDisabled")
        do { try LocalServiceInstaller.uninstall(); model?.localServiceReady = false; model?.localServiceStatus = "本机连接服务已停用；设置和任务记录已保留。" }
        catch { model?.reportError(error) }
    }
}

enum LocalServiceInstaller {
    static let label = "cn.rightmouse.local-bridge"
    private static var domain: String { "gui/\(getuid())" }
    static var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private static func run(_ arguments: [String], allowFailure: Bool = false) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure { throw NSError(domain: "RightMouse.LocalService", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "服务注册失败，请在权限与诊断中修复本机连接。"] ) }
        return process.terminationStatus
    }
    static func install(identity: LocalXPCIdentity, force: Bool) throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/RightMouseBridge.app/Contents/MacOS/RightMouseBridge")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LocalXPCError.unavailable }
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.path],
            "MachServices": [identity.registrationService: true, identity.discoveryService: true],
            "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
        let encoded = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let changed = (try? Data(contentsOf: plistURL)) != encoded
        let loaded = try run(["print", domain + "/" + label], allowFailure: true) == 0
        if !changed && loaded && !force { return }
        if loaded { _ = try run(["bootout", domain + "/" + label]) }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
        _ = try run(["bootstrap", domain, plistURL.path])
    }
    static func uninstall() throws {
        if try run(["print", domain + "/" + label], allowFailure: true) == 0 { _ = try run(["bootout", domain + "/" + label]) }
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
    }
}
