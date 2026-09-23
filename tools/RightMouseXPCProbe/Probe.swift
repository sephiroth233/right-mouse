import Foundation
import Darwin

@objc protocol RightMouseProbeProtocol {
    func ping(_ nonce: String, reply: @escaping (String) -> Void)
}

final class ProbeService: NSObject, RightMouseProbeProtocol {
    func ping(_ nonce: String, reply: @escaping (String) -> Void) {
        guard nonce.utf8.count <= 128 else { reply("rejected"); return }
        print("PING accepted", terminator: "\n"); fflush(stdout)
        reply("RightMouse XPC: " + nonce)
    }
}

final class ProbeListener: NSObject, NSXPCListenerDelegate {
    private let service = ProbeService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: RightMouseProbeProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

@main enum ProbeMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else { exit(64) }
        let mode = arguments[1], serviceName = arguments[2], requirement = arguments[3]
        if mode == "server" {
            let listener = NSXPCListener(machServiceName: serviceName)
            listener.setConnectionCodeSigningRequirement(requirement)
            let delegate = ProbeListener()
            listener.delegate = delegate
            listener.resume()
            print("READY", terminator: "\n"); fflush(stdout)
            withExtendedLifetime(delegate) { RunLoop.current.run() }
        } else {
            #if ROGUE
            print("ROGUE client with same signing identifier")
            #endif
            let connection = NSXPCConnection(machServiceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: RightMouseProbeProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                print("REJECTED: \(error.localizedDescription)"); fflush(stdout); exit(2)
            } as! RightMouseProbeProtocol
            let nonce = UUID().uuidString
            proxy.ping(nonce) { result in
                let accepted = result == "RightMouse XPC: " + nonce
                print(accepted ? "PASS authenticated ping" : "FAIL unexpected reply"); fflush(stdout)
                connection.invalidate(); exit(accepted ? 0 : 3)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { print("TIMEOUT"); fflush(stdout); exit(4) }
            RunLoop.current.run()
        }
    }
}
