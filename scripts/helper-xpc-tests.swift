import Foundation
import Security

@main
struct HelperXPCTests {
    static func ownHash() throws -> String {
        var code: SecCode?
        precondition(SecCodeCopySelf([], &code) == errSecSuccess)
        var staticCode: SecStaticCode?
        precondition(SecCodeCopyStaticCode(code!, [], &staticCode) == errSecSuccess)
        var info: CFDictionary?
        precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
        let hash = (info! as NSDictionary)[kSecCodeInfoUnique] as! Data
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func probe(hash: String, expectRejected: Bool) async throws {
        let delegate = EnergyHelper(clientHash: hash, ownerUID: getuid())
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let succeeded: Bool = await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
            let gate = ReplyGate(continuation, connection)
            connection.invalidationHandler = { gate.finish(false) }
            connection.resume()
            let remote = connection.remoteObjectProxyWithErrorHandler { _ in gate.finish(false) } as! EnergyHelperProtocol
            remote.ping { version in
                guard version == "1" else { gate.finish(false); return }
                remote.setMode(99, source: "AC Power") { error in gate.finish(error != nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { gate.finish(false) }
        }
        withExtendedLifetime(delegate) {}
        precondition(succeeded != expectRejected)
    }

    static func main() async throws {
        try await probe(hash: ownHash(), expectRejected: false)
        try await probe(hash: String(repeating: "0", count: 40), expectRejected: true)
        print("PASS: signed client accepted; invalid mode rejected; wrong client signature rejected")
    }
}

final class ReplyGate: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<Bool, Never>?
    let connection: NSXPCConnection
    init(_ continuation: CheckedContinuation<Bool, Never>, _ connection: NSXPCConnection) {
        self.continuation = continuation; self.connection = connection
    }
    func finish(_ value: Bool) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return }
        connection.invalidationHandler = nil
        connection.invalidate()
        pending.resume(returning: value)
    }
}
