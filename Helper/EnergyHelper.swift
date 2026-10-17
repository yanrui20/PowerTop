import Foundation

final class EnergyHelper: NSObject, NSXPCListenerDelegate, EnergyHelperProtocol {
    let clientRequirement: String
    let ownerUID: uid_t
    private let queue = DispatchQueue(label: "PowerTop.energy-helper")

    init(clientHash: String, ownerUID: uid_t) {
        clientRequirement = "cdhash H\"\(clientHash)\""
        self.ownerUID = ownerUID
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == ownerUID else { return false }
        // The OS checks each XPC message against the exact build approved during installation.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(withReply reply: @escaping (String) -> Void) { reply(EnergyHelperConstants.version) }

    func setMode(_ raw: Int, source: String, withReply reply: @escaping (String?) -> Void) {
        guard let mode = EnergyMode(rawValue: raw), let powerSource = EnergyPowerSource(rawValue: source) else {
            reply("Invalid energy mode or power source.")
            return
        }
        queue.async {
            do {
                let settings = EnergyModeSetting.parse(try self.run(["-g", "custom"]))
                guard let setting = settings[powerSource] else { throw EnergyModeError.unavailable }
                _ = try setting.command(for: mode, source: powerSource) // Validate hardware support.
                let key = setting.supportsHighPower ? "powermode" : "lowpowermode"
                _ = try self.run([powerSource.argument, key, String(mode.rawValue)])
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw EnergyModeError.commandFailed(output) }
        return output
    }
}
