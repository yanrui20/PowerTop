import Foundation
import Security

/// One optional root service for two fixed operations: battery sampling and energy modes.
actor PrivilegedEnergyHelper {
    static let shared = PrivilegedEnergyHelper()
    static let preferenceKey = "useEnergyHelper"

    private func helperURL() throws -> URL {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/PowerTopEnergyHelper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw EnergyModeError.commandFailed(String(localized: "Energy helper is missing. Reinstall PowerTop."))
        }
        return url
    }

    private func codeHash(at url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw EnergyModeError.commandFailed("Cannot inspect code signature.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else {
            throw EnergyModeError.commandFailed("PowerTop must be signed before enabling its helper.")
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func install() async throws {
        let helper = try helperURL()
        let helperHash = try codeHash(at: helper)
        let clientHash = try codeHash(at: Bundle.main.bundleURL)
        let plist: [String: Any] = [
            "Label": EnergyHelperConstants.service,
            "ProgramArguments": [EnergyHelperConstants.executable, clientHash, String(getuid())],
            "MachServices": [EnergyHelperConstants.service: true],
            "AssociatedBundleIdentifiers": ["com.kdolphin.PowerTop"],
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let command = """
        set -e
        \(Self.verificationCommand(hash: helperHash, path: helper.path))
        /bin/launchctl bootout system/\(EnergyHelperConstants.service) >/dev/null 2>&1 || true
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        /usr/bin/install -o root -g wheel -m 755 \(Self.quote(helper.path)) \(EnergyHelperConstants.executable)
        \(Self.verificationCommand(hash: helperHash, path: EnergyHelperConstants.executable))
        /bin/echo '\(data.base64EncodedString())' | /usr/bin/base64 -D > \(EnergyHelperConstants.plist)
        /usr/sbin/chown root:wheel \(EnergyHelperConstants.plist)
        /bin/chmod 644 \(EnergyHelperConstants.plist)
        /bin/launchctl bootstrap system \(EnergyHelperConstants.plist)
        """
        try authorize(command)
        try await ping()
    }

    func uninstall() throws {
        try authorize("""
        set -e
        /bin/launchctl bootout system/\(EnergyHelperConstants.service) >/dev/null 2>&1 || true
        /bin/rm -f \(EnergyHelperConstants.plist) \(EnergyHelperConstants.executable)
        """)
    }

    func ping() async throws { try await request(mode: nil, source: nil) }
    private func requireEnabledService() throws {
        guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else {
            throw EnergyModeError.commandFailed(String(localized: "Administrator service is unavailable. Enable or repair it first."))
        }
    }

    func apply(_ mode: EnergyMode, source: EnergyPowerSource) async throws {
        try requireEnabledService()
        try await request(mode: mode, source: source)
    }

    func requestBatterySample() async throws {
        try requireEnabledService()
        try await request(mode: nil, source: nil, sample: true)
    }

    private func request(mode: EnergyMode?, source: EnergyPowerSource?, sample: Bool = false) async throws {
        let expectedHash = try codeHash(at: helperURL())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(machServiceName: EnergyHelperConstants.service, options: .privileged)
            connection.setCodeSigningRequirement("cdhash H\"\(expectedHash)\"")
            connection.remoteObjectInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
            let gate = EnergyHelperReply(continuation, connection: connection)
            connection.invalidationHandler = { gate.finish(EnergyModeError.commandFailed(String(localized: "Administrator service is unavailable. Enable or repair it first."))) }
            connection.interruptionHandler = connection.invalidationHandler
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { gate.finish($0) } as? EnergyHelperProtocol
            guard let proxy else { gate.finish(EnergyModeError.unavailable); return }
            // Check protocol compatibility before invoking a new operation.
            proxy.ping { version in
                guard version == EnergyHelperConstants.version else {
                    gate.finish(EnergyModeError.commandFailed(String(localized: "Administrator service is unavailable. Enable or repair it first.")))
                    return
                }
                if sample {
                    proxy.requestBatterySample { error in gate.finish(error.map { EnergyModeError.commandFailed($0) }) }
                } else if let mode, let source {
                    proxy.setMode(mode.rawValue, source: source.rawValue) { error in
                        gate.finish(error.map { EnergyModeError.commandFailed($0) })
                    }
                } else { gate.finish(nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                gate.finish(EnergyModeError.commandFailed(String(localized: "Administrator service is unavailable. Enable or repair it first.")))
            }
        }
    }

    // codesign treats a requirement as a file path unless it starts with "=".
    // XPC's requirement API takes the expression directly and must NOT use this prefix.
    static func verificationCommand(hash: String, path: String) -> String {
        "/usr/bin/codesign --verify --strict -R " + quote("=cdhash H\"\(hash)\"") + " " + quote(path)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func authorizationScript(_ command: String, requiresAdmin: Bool = true) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        try
            do shell script "\(escaped)"\(requiresAdmin ? " with administrator privileges" : "")
        on error errorMessage number errorNumber
            if errorNumber is -128 then
                return "POWERTOP_AUTH_CANCELLED"
            end if
            error errorMessage number errorNumber
        end try
        """
    }

    private func authorize(_ command: String) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.authorizationScript(command)]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "POWERTOP_AUTH_CANCELLED" { throw EnergyModeError.commandFailed(String(localized: "Administrator authorization cancelled.")) }
        guard process.terminationStatus == 0 else { throw EnergyModeError.commandFailed(output) }
    }
}

private final class EnergyHelperReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let connection: NSXPCConnection
    init(_ continuation: CheckedContinuation<Void, Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }
    func finish(_ error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}
