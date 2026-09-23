#if os(macOS)
import Foundation

@objc public protocol LocalBridgeRegistration {
    func registerHost(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void)
}
@objc public protocol LocalBridgeDiscovery {
    func discover(_ nonce: String, reply: @escaping (String, NSXPCListenerEndpoint?) -> Void)
}
@objc public protocol LocalFinderService {
    func handshake(_ nonce: String, reply: @escaping (String) -> Void)
    func perform(_ payload: Data, reply: @escaping (Bool) -> Void)
}

/// Immutable build identity. A certificate fingerprint is a requirement, never a
/// system trust anchor; no caller-supplied identifier can widen this policy.
public struct LocalXPCIdentity {
    public let certificate: String
    public let servicePrefix: String
    public init?(bundle: Bundle = .main) {
        guard bundle.object(forInfoDictionaryKey: "RightMouseAuthenticatedXPC") as? Bool == true,
              let value = bundle.object(forInfoDictionaryKey: "RightMouseLocalCertificate") as? String,
              value.count == 40, value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        certificate = value.lowercased()
        servicePrefix = "cn.rightmouse.bridge." + certificate.prefix(16)
    }
    public var registrationService: String { servicePrefix + ".host" }
    public var discoveryService: String { servicePrefix + ".finder" }
    public func requirement(_ identifier: String) -> String {
        precondition(["cn.rightmouse.RightMouse", "cn.rightmouse.RightMouse.FinderExtension", "cn.rightmouse.RightMouse.Bridge"].contains(identifier))
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(certificate)\""
    }
    public static func validNonce(_ nonce: String) -> Bool { UUID(uuidString: nonce) != nil && nonce.utf8.count == 36 }
    public static func response(_ nonce: String) -> String { "RightMouse-XPC-1:" + nonce }
}

public enum LocalXPCError: Error { case unavailable, timeout, rejected }

/// XPC invalidation, reply and timeout may race. Resume exactly once and never
/// retry an action after sending it: the durable command ledger owns duplicates.
private final class XPCReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
public enum LocalXPCCall {
    public static func invoke<Value>(_ connection: NSXPCConnection, timeout: Double = 5,
        send: @escaping (Any, @escaping (Value) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result = XPCReply(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in result.finish(.failure(LocalXPCError.unavailable)) }
            send(proxy) { result.finish(.success($0)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { result.finish(.failure(LocalXPCError.timeout)) }
        }
    }
}
#endif
