import Foundation
import Observation

protocol EnergyModeBackend: Sendable {
    func read() async throws -> [EnergyPowerSource: EnergyModeSetting]
    func apply(_ mode: EnergyMode, source: EnergyPowerSource, setting: EnergyModeSetting) async throws
}

/// Blocking child processes run on this actor, away from the UI executor.
actor SystemEnergyModeBackend: EnergyModeBackend {
    func read() async throws -> [EnergyPowerSource: EnergyModeSetting] {
        let output = try run("/usr/bin/pmset", arguments: ["-g", "custom"])
        let settings = EnergyModeSetting.parse(output)
        guard !settings.isEmpty else { throw EnergyModeError.unavailable }
        return settings
    }

    func apply(_ mode: EnergyMode, source: EnergyPowerSource, setting: EnergyModeSetting) async throws {
        let command = try setting.command(for: mode, source: source)
        if UserDefaults.standard.bool(forKey: PrivilegedEnergyHelper.preferenceKey) {
            try await PrivilegedEnergyHelper.shared.apply(mode, source: source)
            return
        }
        // macOS owns the password prompt. No password is stored, and no helper is installed.
        let script = """
        try
            do shell script "\(command)" with administrator privileges
        on error errorMessage number errorNumber
            if errorNumber is -128 then
                return "POWERTOP_AUTH_CANCELLED"
            end if
            error errorMessage number errorNumber
        end try
        """
        let output = try run("/usr/bin/osascript", arguments: ["-e", script])
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "POWERTOP_AUTH_CANCELLED" {
            throw EnergyModeError.cancelled
        }
    }

    private func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw EnergyModeError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}

@MainActor
@Observable
final class EnergyModeController {
    private(set) var settings: [EnergyPowerSource: EnergyModeSetting] = [:]
    private(set) var isChanging = false
    private(set) var quickSwitchEnabled = UserDefaults.standard.bool(forKey: PrivilegedEnergyHelper.preferenceKey)
    var helperInstalled: Bool { FileManager.default.fileExists(atPath: EnergyHelperConstants.executable) }

    func configureQuickSwitch(enabled: Bool) async {
        guard !isChanging, !isRefreshing else { return }
        isChanging = true
        errorMessage = nil
        lastErrorWasReadFailure = false
        defer { isChanging = false }
        do {
            if enabled { try await PrivilegedEnergyHelper.shared.install() }
            else { try await PrivilegedEnergyHelper.shared.uninstall() }
            quickSwitchEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: PrivilegedEnergyHelper.preferenceKey)
        } catch { errorMessage = error.localizedDescription }
    }
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private var lastErrorWasReadFailure = false
    private let backend: any EnergyModeBackend

    init(backend: any EnergyModeBackend = SystemEnergyModeBackend()) {
        self.backend = backend
    }

    @ObservationIgnored private var monitoringTask: Task<Void, Never>?

    /// Keep the menu bar color current even when the panel is closed. This cadence
    /// is independent of the user's power-sensor interval (which can be 300 seconds).
    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    deinit { monitoringTask?.cancel() }

    func refresh() async {
        guard !isChanging, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            settings = try await backend.read()
            if lastErrorWasReadFailure { errorMessage = nil }
            lastErrorWasReadFailure = false
        } catch {
            settings = [:]
            lastErrorWasReadFailure = true
            errorMessage = error.localizedDescription
        }
    }

    func select(_ mode: EnergyMode, source: EnergyPowerSource) async {
        guard !isChanging, !isRefreshing, let setting = settings[source], setting.mode != mode else { return }
        isChanging = true
        errorMessage = nil
        lastErrorWasReadFailure = false
        defer { isChanging = false }
        do {
            try await backend.apply(mode, source: source, setting: setting)
            settings = try await backend.read()
            guard settings[source]?.mode == mode else { throw EnergyModeError.verificationFailed }
        } catch {
            errorMessage = error.localizedDescription
            // Re-read even on cancellation/failure: another app may have changed the setting.
            settings = (try? await backend.read()) ?? [:]
        }
    }
}
