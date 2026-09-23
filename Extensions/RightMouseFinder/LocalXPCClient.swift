import Foundation
import AppKit
import RightMouseCore

@MainActor final class LocalXPCClient {
    private let identity: LocalXPCIdentity
    private var pending = 0
    init(identity: LocalXPCIdentity) { self.identity = identity }
    func send(_ request: CommandRequest, wakeHost: @escaping () -> Void, failure: @escaping () -> Void) {
        guard pending < 8 else { failure(); return }
        pending += 1
        Task {
            defer { pending -= 1 }
            do {
                let url = try LocalFinderRequest.encode(request, localModeEnabled: true)
                let data = Data(url.absoluteString.utf8)
                var endpoint: NSXPCListenerEndpoint?
                // Wake only on a user operation, never while constructing a menu.
                wakeHost()
                for _ in 0..<20 {
                    do { endpoint = try await discover() } catch { }
                    if endpoint != nil { break }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                guard let endpoint else { throw LocalXPCError.unavailable }
                let connection = NSXPCConnection(listenerEndpoint: endpoint)
                connection.remoteObjectInterface = NSXPCInterface(with: LocalFinderService.self)
                connection.setCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse"))
                connection.resume(); defer { connection.invalidate() }
                let nonce = UUID().uuidString
                let response: String = try await LocalXPCCall.invoke(connection) { proxy, reply in
                    (proxy as! LocalFinderService).handshake(nonce, reply: reply)
                }
                guard response == LocalXPCIdentity.response(nonce) else { throw LocalXPCError.rejected }
                // No paths or operations leave this process before the authenticated
                // response above. After send, never automatically replay the action.
                let accepted: Bool = try await LocalXPCCall.invoke(connection) { proxy, reply in
                    (proxy as! LocalFinderService).perform(data, reply: reply)
                }
                guard accepted else { throw LocalXPCError.rejected }
            } catch { failure() }
        }
    }
    private func discover() async throws -> NSXPCListenerEndpoint? {
        let connection = NSXPCConnection(machServiceName: identity.discoveryService)
        connection.remoteObjectInterface = NSXPCInterface(with: LocalBridgeDiscovery.self)
        connection.setCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse.Bridge"))
        connection.resume(); defer { connection.invalidate() }
        let nonce = UUID().uuidString
        let result: (String, NSXPCListenerEndpoint?) = try await LocalXPCCall.invoke(connection, timeout: 0.5) { proxy, reply in
            (proxy as! LocalBridgeDiscovery).discover(nonce) { reply(($0, $1)) }
        }
        guard result.0 == LocalXPCIdentity.response(nonce) else { throw LocalXPCError.rejected }
        return result.1
    }
}
