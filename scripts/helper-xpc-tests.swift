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
        let delegate = EnergyHelper(clientHash: hash, ownerUID: getuid(), sampleRequest: { 1 })
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
                guard version == EnergyHelperConstants.version else { gate.finish(false); return }
                remote.setMode(99, source: "AC Power") { error in
                    guard error != nil else { gate.finish(false); return }
                    remote.requestBatterySample { sampleError in
                        guard sampleError == nil else { gate.finish(false); return }
                        remote.setStartupDaemonEnabled(false, sourcePath: "/tmp/invalid.plist", label: "com.apple.security") { error in
                            gate.finish(error != nil)
                        }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { gate.finish(false) }
        }
        withExtendedLifetime(delegate) {}
        precondition(succeeded != expectRejected)
    }

    static func main() async throws {
        try await probe(hash: ownHash(), expectRejected: false)
        try await probe(hash: String(repeating: "0", count: 40), expectRejected: true)
        let failed = EnergyHelper(clientHash: try ownHash(), ownerUID: getuid(), sampleRequest: { -1 })
        let error: String? = await withCheckedContinuation { continuation in
            failed.requestBatterySample { continuation.resume(returning: $0) }
        }
        precondition(error != nil)
        for label in ["com.apple.security", EnergyHelperConstants.service, "a\n", "../../bad", "x;id", ""] {
            precondition(!StartupServicePolicy.validLabel(label))
        }
        for path in ["/tmp/invalid.plist", "/Library/LaunchDaemons/../LaunchAgents/bad.plist", EnergyHelperConstants.plist] {
            precondition(!StartupServicePolicy.validDaemon(path: path, label: "example"))
        }
        let listed = StartupServicePolicy.loadedLabels("PID\tStatus\tLabel\n-\t0\texample.waiting\n123\t-9\texample.running\n")
        precondition(listed == ["example.waiting", "example.running"], "No PID still means loaded")
        precondition(StartupServicePolicy.loadedLabels("permission denied") == nil)
        precondition(StartupServicePolicy.loadedLabels("PID Status Label\nmalformed") == nil)
        precondition(StartupServicePolicy.loadedLabels("PID Status Label") == [])
        precondition(!StartupServicePolicy.supportsCurrentSession(["LimitLoadToSessionType": ["LoginWindow"]]))
        precondition(StartupServicePolicy.supportsCurrentSession(["LimitLoadToSessionType": "Aqua"]))
        var commands: [[String]] = []
        var loaded = false
        func runner(_ args: [String]) throws -> String {
            commands.append(args)
            if args.first == "bootstrap" { loaded = true }
            if args.first == "bootout" { loaded = false }
            return "PID\tStatus\tLabel\n" + (loaded ? "-\t0\texample.service\n" : "")
        }
        try StartupServiceAction.apply(enabled: true, domain: "gui/501", label: "example.service", path: "/tmp/example.plist", run: runner)
        precondition(commands.contains(["bootstrap", "gui/501", "/tmp/example.plist"]))
        commands = []
        try StartupServiceAction.apply(enabled: true, domain: "gui/501", label: "example.service", path: "/tmp/example.plist", run: runner)
        precondition(!commands.contains(where: { $0.first == "bootstrap" }), "Already loaded service must not restart")
        commands = []
        try StartupServiceAction.apply(enabled: false, domain: "gui/501", label: "example.service", path: "/tmp/example.plist", run: runner)
        precondition(commands.first == ["disable", "gui/501/example.service"])
        precondition(commands.contains(["bootout", "gui/501/example.service"]) && !loaded)
        commands = []
        try StartupServiceAction.apply(enabled: false, domain: "gui/501", label: "example.service", path: "/tmp/example.plist", run: runner)
        precondition(!commands.contains(where: { $0.first == "bootout" }), "Already unloaded services are successful without another bootout")
        do {
            try StartupServiceAction.apply(enabled: false, domain: "system", label: "example.service", path: "/tmp/example.plist") { _ in "PID Status Label\n123 0 example.service\n" }
            preconditionFailure("An unload that leaves the service registered must not succeed")
        } catch {}
        do {
            try StartupServiceAction.apply(enabled: false, domain: "system", label: "example.service", path: "/tmp/example.plist") { _ in "invalid response" }
            preconditionFailure("An unreadable state must not count as unloaded")
        } catch {}
        do {
            try StartupServiceAction.apply(enabled: true, domain: "system", label: "example.service", path: "/tmp/example.plist") { _ in "PID Status Label\n" }
            preconditionFailure("A load that does not register must fail verification")
        } catch {}
        let filtered = StartupServicePolicy.backgroundRecords("Records for UID 501 : user\nkept\nRecords for UID 502 : other\nsecret\nRecords for UID -2 : shared\nshared", ownerUID: 501)
        precondition(filtered.contains("kept") && filtered.contains("shared") && !filtered.contains("secret"))
        print("PASS: signed service validates modes, sampling and startup mutations; wrong signatures, unsafe paths/labels and other users' records rejected; no real startup item changed")
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
