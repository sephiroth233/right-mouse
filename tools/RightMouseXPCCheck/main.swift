import Foundation
import RightMouseCore
import Darwin

@main enum XPCCheck {
    static func main() async {
        do {
            guard let identity = LocalXPCIdentity(), CommandLine.arguments.count >= 2 else { exit(64) }
            let mode = CommandLine.arguments[1]
            let bridge = NSXPCConnection(machServiceName: identity.discoveryService)
            bridge.remoteObjectInterface = NSXPCInterface(with: LocalBridgeDiscovery.self)
            bridge.setCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse.Bridge"))
            bridge.resume(); defer { bridge.invalidate() }
            let nonce = UUID().uuidString
            let found: (String, NSXPCListenerEndpoint?) = try await LocalXPCCall.invoke(bridge, timeout: 3) { proxy, reply in
                (proxy as! LocalBridgeDiscovery).discover(nonce) { reply(($0, $1)) }
            }
            guard found.0 == LocalXPCIdentity.response(nonce), let endpoint = found.1 else { throw LocalXPCError.unavailable }
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: LocalFinderService.self)
            connection.setCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse"))
            connection.resume(); defer { connection.invalidate() }
            if mode != "no-handshake" {
                let response: String = try await LocalXPCCall.invoke(connection) { proxy, reply in
                    (proxy as! LocalFinderService).handshake(nonce, reply: reply)
                }
                guard response == LocalXPCIdentity.response(nonce) else { throw LocalXPCError.rejected }
            }
            if mode == "ping" { print("PASS authenticated host handshake"); return }
            guard CommandLine.arguments.count == 3 else { exit(64) }
            // Input fixtures live only in .build, never bundled in the application.
            let data = Data(CommandLine.arguments[2].utf8)
            let accepted: Bool = try await LocalXPCCall.invoke(connection) { proxy, reply in
                (proxy as! LocalFinderService).perform(data, reply: reply)
            }
            print(accepted ? "ACCEPTED" : "REJECTED")
            exit(accepted ? 0 : 2)
        } catch { print("CONNECTION REJECTED"); exit(3) }
    }
}
