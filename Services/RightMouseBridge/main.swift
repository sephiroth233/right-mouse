import Foundation
import RightMouseCore
import Darwin

// Rendezvous only. This process never accepts paths, URLs, commands or files.
final class Registry {
    let lock = NSLock()
    private var endpoint: NSXPCListenerEndpoint?
    private var owner: UUID?
    func put(_ value: NSXPCListenerEndpoint, owner: UUID) { lock.lock(); defer { lock.unlock() }; endpoint = value; self.owner = owner }
    func clear(_ id: UUID) { lock.lock(); defer { lock.unlock() }; if owner == id { endpoint = nil; owner = nil } }
    func get() -> NSXPCListenerEndpoint? { lock.lock(); defer { lock.unlock() }; return endpoint }
}
final class Registration: NSObject, LocalBridgeRegistration {
    let registry: Registry, owner: UUID
    init(_ registry: Registry, owner: UUID) { self.registry = registry; self.owner = owner }
    func registerHost(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) { registry.put(endpoint, owner: owner); reply(true) }
}
final class Discovery: NSObject, LocalBridgeDiscovery {
    let registry: Registry
    init(_ registry: Registry) { self.registry = registry }
    func discover(_ nonce: String, reply: @escaping (String, NSXPCListenerEndpoint?) -> Void) {
        guard LocalXPCIdentity.validNonce(nonce) else { reply("", nil); return }
        reply(LocalXPCIdentity.response(nonce), registry.get())
    }
}
final class Delegate: NSObject, NSXPCListenerDelegate {
    let registry: Registry, registration: Bool
    init(_ registry: Registry, registration: Bool) { self.registry = registry; self.registration = registration }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        if registration {
            let id = UUID()
            connection.exportedInterface = NSXPCInterface(with: LocalBridgeRegistration.self)
            connection.exportedObject = Registration(registry, owner: id)
            connection.invalidationHandler = { [registry] in registry.clear(id) }
            connection.interruptionHandler = { connection.invalidate() }
        } else {
            connection.exportedInterface = NSXPCInterface(with: LocalBridgeDiscovery.self)
            connection.exportedObject = Discovery(registry)
        }
        connection.resume(); return true
    }
}
guard let identity = LocalXPCIdentity() else { exit(78) }
let registry = Registry()
let hostDelegate = Delegate(registry, registration: true)
let finderDelegate = Delegate(registry, registration: false)
let host = NSXPCListener(machServiceName: identity.registrationService)
host.setConnectionCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse"))
host.delegate = hostDelegate; host.resume()
let finder = NSXPCListener(machServiceName: identity.discoveryService)
finder.setConnectionCodeSigningRequirement(identity.requirement("cn.rightmouse.RightMouse.FinderExtension"))
finder.delegate = finderDelegate; finder.resume()
RunLoop.current.run()
