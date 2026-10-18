import Foundation
import Security

actor TestBackend: EnergyModeBackend {
    enum Behavior { case apply, ignore, cancel, fail }
    var behavior: Behavior = .apply
    var settings: [EnergyPowerSource: EnergyModeSetting] = [
        .battery: .init(mode: .low, supportsHighPower: true),
        .adapter: .init(mode: .high, supportsHighPower: true)
    ]
    var readFails = false
    var reads = 0
    func readCount() -> Int { reads }
    func configure(_ behavior: Behavior) { self.behavior = behavior }
    func failReads(_ value: Bool) { readFails = value }
    func read() async throws -> [EnergyPowerSource: EnergyModeSetting] {
        reads += 1
        if readFails { throw EnergyModeError.unavailable }
        return settings
    }
    func apply(_ mode: EnergyMode, source: EnergyPowerSource, setting: EnergyModeSetting) async throws {
        switch behavior {
        case .apply: settings[source] = .init(mode: mode, supportsHighPower: setting.supportsHighPower)
        case .ignore: break
        case .cancel: throw EnergyModeError.cancelled
        case .fail: throw EnergyModeError.commandFailed("Permission denied")
        }
    }
}

// Hold one background read across a completed user action to exercise stale results.
actor DelayedModeBackend: EnergyModeBackend {
    var current: [EnergyPowerSource: EnergyModeSetting] = [
        .adapter: .init(mode: .automatic, supportsHighPower: true)
    ]
    var holdNext = false
    var pending: CheckedContinuation<[EnergyPowerSource: EnergyModeSetting], Error>?
    func hold() { holdNext = true }
    func isPending() -> Bool { pending != nil }
    func finish(fail: Bool) {
        if fail { pending?.resume(throwing: EnergyModeError.unavailable) }
        else { pending?.resume(returning: [.adapter: .init(mode: .automatic, supportsHighPower: true)]) }
        pending = nil
    }
    func read() async throws -> [EnergyPowerSource: EnergyModeSetting] {
        if holdNext {
            holdNext = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return current
    }
    func apply(_ mode: EnergyMode, source: EnergyPowerSource, setting: EnergyModeSetting) async throws {
        current[source] = .init(mode: mode, supportsHighPower: true)
    }
}

@main
struct EnergyModeTests {
    static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    static func checkInstallVerification(_ path: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("helper with 'quotes' and spaces")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        var code: SecStaticCode?, info: CFDictionary?
        precondition(SecStaticCodeCreateWithPath(copy as CFURL, [], &code) == errSecSuccess)
        precondition(SecCodeCopySigningInformation(code!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
        let hash = ((info! as NSDictionary)[kSecCodeInfoUnique] as! Data).map { String(format: "%02x", $0) }.joined()
        // Reproduce the original error, then exercise the same generated command
        // and AppleScript escaping used by installation, without root operations.
        let old = try run("/usr/bin/codesign", ["--verify", "--strict", "-R", "cdhash H\"\(hash)\"", copy.path])
        precondition(old.0 != 0 && old.1.contains("No such file or directory"))
        let command = PrivilegedEnergyHelper.verificationCommand(hash: hash, path: copy.path)
        let script = PrivilegedEnergyHelper.authorizationScript(command, requiresAdmin: false)
        let valid = try run("/usr/bin/osascript", ["-e", script])
        precondition(valid.0 == 0, valid.1)
        let invalidCommand = PrivilegedEnergyHelper.verificationCommand(hash: String(repeating: "0", count: 40), path: copy.path)
        let invalid = try run("/usr/bin/osascript", ["-e", PrivilegedEnergyHelper.authorizationScript(invalidCommand, requiresAdmin: false)])
        precondition(invalid.0 != 0)
        print("PASS: original installation error reproduced; fixed verification accepts signed helper and rejects wrong hash through AppleScript, including quoted paths")
    }

    @MainActor static func main() async throws {
        if let path = ProcessInfo.processInfo.environment["POWERTOP_TEST_HELPER"] {
            try checkInstallVerification(path)
        }
        let parsed = EnergyModeSetting.parse("""
        Battery Power:
         powermode 1
         sleep 1
        AC Power:
         powermode 2
        UPS Power:
         powermode 0
        """)
        precondition(parsed.count == 2 && parsed[.battery]?.mode == .low && parsed[.adapter]?.mode == .high)
        let adapter = parsed[.adapter]!
        let highCommand = try adapter.command(for: .high, source: .adapter)
        precondition(highCommand == "/usr/bin/pmset -c powermode 2")
        let automaticCommand = try adapter.command(for: .automatic, source: .battery)
        precondition(automaticCommand == "/usr/bin/pmset -b powermode 0")
        let legacy = EnergyModeSetting.parse("Battery Power:\n lowpowermode 0")[.battery]!
        precondition(legacy.mode == .automatic && !legacy.supportsHighPower)
        let lowCommand = try legacy.command(for: .low, source: .battery)
        precondition(lowCommand == "/usr/bin/pmset -b lowpowermode 1")
        do {
            _ = try legacy.command(for: .high, source: .battery)
            preconditionFailure("Unsupported high power must be rejected")
        } catch EnergyModeError.unsupported { }
        precondition(EnergyModeSetting.parse("Battery Power:\n powermode 7\nAC Power:\n powermode unknown").isEmpty)
        precondition(EnergyModeSetting.parse("powermode 1").isEmpty)
        precondition(EnergyModeSetting.parse("AC Power:\n lowpowermode 2")[.adapter]?.supportsHighPower == false)

        func label(_ percent: Int, _ charging: Bool = false, _ battery: Bool = true,
                   _ power: Bool = false, _ available: Bool = true) -> MenuBarPresentation {
            .init(available: available, percent: percent, charging: charging, onAC: true,
                  showBattery: battery, showPower: power, powerText: "23W")
        }
        precondition(label(76).title.isEmpty && label(76).batteryPercent == 76)
        precondition(label(20, true).symbol == "battery.50")
        precondition(label(76, false, true, true).title == "23W")
        precondition(label(76, false, false, true).symbol == nil)
        precondition(label(76, false, false, false).symbol == "battery.50")
        precondition(label(-1).batteryPercent == 0 && label(120).batteryPercent == 100)
        precondition(label(76, false, true, true, false).batteryPercent == nil)
        precondition(label(0).symbolImage()?.size == label(100).symbolImage()?.size)
        precondition(label(100, true).symbolImage()?.size == label(100).symbolImage()?.size,
                     "Charging must not widen the numbered battery")
        precondition(label(20, true).chargingBadge == .battery)
        precondition(label(20, true, false, false).chargingBadge == .battery)
        precondition(label(20, false).chargingBadge == .none)
        precondition(label(20, true, false, true).chargingBadge == .afterPower)
        precondition(label(20, true, true, true).titleBadgeIndex == nil)
        precondition(label(20, true, true, true, false).chargingBadge == .none)

        let records = try EnergyAppParser.parse([
            "bundle_identifiers": ["helper.one", "helper.two", "app.other"],
            "responsible_bundle_identifiers": ["app.owner", "app.owner", ""],
            "display_names": ["Owner"]
        ])
        precondition(records.map(\.bundleID) == ["app.owner", "app.other"])
        let empty = try EnergyAppParser.parse(["bundle_identifiers": [String]()])
        precondition(empty.isEmpty)
        do { _ = try EnergyAppParser.parse([:]); preconditionFailure("Unknown schema is not an empty result") }
        catch EnergyModeError.unavailable { }
        let suite = "PowerTop.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = PowerMonitor(defaults: defaults)
        precondition(monitor.updateInterval == 2)
        monitor.updateInterval = 7.5
        precondition(PowerMonitor(defaults: defaults).updateInterval == 7.5)
        monitor.updateInterval = 0
        precondition(monitor.updateInterval == 1)
        monitor.updateInterval = 1000
        precondition(monitor.updateInterval == 300)
        monitor.updateInterval = .nan
        precondition(monitor.updateInterval == 2)

        let backend = TestBackend()
        let controller = EnergyModeController(backend: backend)
        await controller.refresh()
        await controller.select(.automatic, source: .adapter)
        precondition(controller.settings[.adapter]?.mode == .automatic)
        precondition(controller.settings[.battery]?.mode == .low, "Other power source must remain unchanged")
        precondition(controller.errorMessage == nil && !controller.isChanging)
        await backend.configure(.ignore)
        await controller.select(.high, source: .adapter)
        precondition(controller.settings[.adapter]?.mode == .automatic && controller.errorMessage != nil)
        await backend.configure(.cancel)
        await controller.select(.high, source: .adapter)
        precondition(controller.settings[.adapter]?.mode == .automatic && controller.errorMessage == EnergyModeError.cancelled.localizedDescription)
        await backend.configure(.fail)
        await controller.select(.high, source: .adapter)
        precondition(controller.errorMessage == "Permission denied" && !controller.isChanging)
        await backend.failReads(true)
        await controller.refresh()
        precondition(controller.settings.isEmpty && !controller.isRefreshing)
        await backend.failReads(false)
        await controller.refresh()
        precondition(controller.settings.count == 2 && controller.errorMessage == nil)
        for fail in [false, true] {
            let delayed = DelayedModeBackend()
            let duringRead = EnergyModeController(backend: delayed)
            await duringRead.refresh()
            await delayed.hold()
            let background = Task { await duringRead.refresh() }
            while !(await delayed.isPending()) { await Task.yield() }
            precondition(duringRead.isRefreshing && !duringRead.isChanging)
            await duringRead.select(.low, source: .adapter)
            precondition(duringRead.settings[.adapter]?.mode == .low, "Click during polling must apply")
            await delayed.finish(fail: fail)
            await background.value
            precondition(duringRead.settings[.adapter]?.mode == .low, "Stale read cannot undo selection")
            precondition(duringRead.errorMessage == nil, "Stale errors cannot replace user action result")
        }
        let cadenceBackend = TestBackend()
        let cadenceModes = EnergyModeController(backend: cadenceBackend)
        let cadence = PowerMonitor(defaults: defaults, energyModes: cadenceModes,
            immediateSampler: .init(request: { throw EnergyModeError.unavailable }, readTimestamp: { 100 }))
        cadence.updateInterval = 300
        cadence.start()
        try await Task.sleep(for: .milliseconds(100))
        let initialReads = await cadenceBackend.readCount()
        precondition(initialReads == 1)
        cadence.updateInterval = 1
        try await Task.sleep(for: .milliseconds(1200))
        let fastReads = await cadenceBackend.readCount()
        precondition(fastReads == initialReads + 2, "Mode cadence must follow the changed refresh interval")
        cadence.updateInterval = 300
        try await Task.sleep(for: .milliseconds(1200))
        let slowReads = await cadenceBackend.readCount()
        precondition(slowReads == fastReads + 1, "Old frequent timer must be cancelled")
        cadence.stop()
        if CommandLine.arguments.contains("--read-system") {
            let records = try await SystemEnergyAppReader().read()
            print("System significant-energy apps: \(records.map(\.bundleID))")
            let live = try await SystemEnergyModeBackend().read()
            for source in EnergyPowerSource.allCases {
                if let setting = live[source] {
                    print("\(source.rawValue): \(setting.mode), high power supported: \(setting.supportsHighPower)")
                }
            }
        }
        print("PASS: clicks during background reads, stale result/error rejection, parsing, source isolation, unsupported modes, cancellation, verification, read failures, menu bar display")
    }
}
