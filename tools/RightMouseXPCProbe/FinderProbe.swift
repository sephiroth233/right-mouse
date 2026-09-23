import Foundation
import AppKit
import FinderSync
import OSLog

@objc protocol RightMouseProbeProtocol {
    func ping(_ nonce: String, reply: @escaping (String) -> Void)
}

final class FinderProbe: FIFinderSync {
    private let logger = Logger(subsystem: "cn.rightmouse.XPCProbe", category: "Finder")
    private var status = "正在连接"
    private var connection: NSXPCConnection?
    override init() {
        super.init()
        guard let directory = Bundle.main.object(forInfoDictionaryKey: "ProbeDirectory") as? String,
              let service = Bundle.main.object(forInfoDictionaryKey: "ProbeService") as? String,
              let requirement = Bundle.main.object(forInfoDictionaryKey: "ProbeServerRequirement") as? String,
              let nonce = Bundle.main.object(forInfoDictionaryKey: "ProbeRunID") as? String else { return }
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: directory, isDirectory: true)]
        logger.notice("Finder probe started: \(nonce, privacy: .public)")
        let connection = NSXPCConnection(machServiceName: service)
        connection.remoteObjectInterface = NSXPCInterface(with: RightMouseProbeProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume(); self.connection = connection
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.logger.error("Finder probe rejected: \(nonce, privacy: .public); \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { self?.status = "连接失败" }
        } as! RightMouseProbeProtocol
        // No filesystem context or user information is sent in this handshake.
        proxy.ping(nonce) { [weak self] result in
            let passed = result == "RightMouse XPC: " + nonce
            self?.logger.notice("Finder authenticated ping passed: \(passed); run: \(nonce, privacy: .public)")
            DispatchQueue.main.async { self?.status = passed ? "连接成功，无 App Group" : "回复异常" }
        }
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "RightMouse XPC 测试：" + status, action: nil, keyEquivalent: "")
        item.isEnabled = false; menu.addItem(item)
        return menu
    }
}
