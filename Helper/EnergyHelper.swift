import Foundation

final class EnergyHelper: NSObject, NSXPCListenerDelegate, EnergyHelperProtocol {
    let clientRequirement: String
    let ownerUID: uid_t
    private let sampleRequest: @Sendable () -> Int32
    private let queue = DispatchQueue(label: "PowerTop.energy-helper")
    private let startupQueue = DispatchQueue(label: "PowerTop.startup-helper")

    init(clientHash: String, ownerUID: uid_t, sampleRequest: @escaping @Sendable () -> Int32 = { SystemBatterySampling.request() }) {
        self.sampleRequest = sampleRequest
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

    func readStartupState(withReply reply: @escaping (String?, String?, String?, String?) -> Void) {
        startupQueue.async {
            do {
                let state = try self.run(["print-disabled", "system"], executable: "/bin/launchctl")
                let records = try self.run(["dumpbtm"], executable: "/usr/bin/sfltool")
                let loaded = try self.run(["list"], executable: "/bin/launchctl")
                reply(state, StartupServicePolicy.backgroundRecords(records, ownerUID: self.ownerUID), loaded, nil)
            } catch { reply(nil, nil, nil, error.localizedDescription) }
        }
    }

    func setStartupDaemonEnabled(_ enabled: Bool, sourcePath: String, label: String, withReply reply: @escaping (String?) -> Void) {
        startupQueue.async {
            guard StartupServicePolicy.validDaemon(path: sourcePath, label: label) else {
                reply("This startup service cannot be changed. Refresh the list and check its source file.")
                return
            }
            do {
                try StartupServiceAction.apply(enabled: enabled, domain: "system", label: label, path: sourcePath) {
                    try self.run($0, executable: "/bin/launchctl")
                }
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    func requestBatterySample(withReply reply: @escaping (String?) -> Void) {
        queue.async {
            let status = self.sampleRequest()
            reply(SystemBatterySampling.requestWasAccepted(status) ? nil
                  : String(format: "System sampling request failed (0x%08x).", UInt32(bitPattern: status)))
        }
    }

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

    private func run(_ arguments: [String], executable: String = "/usr/bin/pmset") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        try process.run()
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw EnergyModeError.commandFailed(output) }
        return output
    }
}
