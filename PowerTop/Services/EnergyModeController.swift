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
        _ = try setting.command(for: mode, source: source)
        try await PrivilegedEnergyHelper.shared.apply(mode, source: source)
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
    private(set) var isAuthorizing = false
    private(set) var authorizationError: String?
    var isBusy: Bool { isChanging || isAuthorizing }
    private(set) var isAdministratorAuthorized = UserDefaults.standard.bool(forKey: PrivilegedEnergyHelper.preferenceKey)
    var helperInstalled: Bool { FileManager.default.fileExists(atPath: EnergyHelperConstants.executable) }

    func configureAdministratorAuthorization(enabled: Bool) async {
        guard !isBusy else { return }
        operationRevision &+= 1
        isAuthorizing = true
        authorizationError = nil
        defer { isAuthorizing = false }
        do {
            if enabled { try await PrivilegedEnergyHelper.shared.install() }
            else { try await PrivilegedEnergyHelper.shared.uninstall() }
            isAdministratorAuthorized = enabled
            UserDefaults.standard.set(enabled, forKey: PrivilegedEnergyHelper.preferenceKey)
        } catch { authorizationError = error.localizedDescription }
    }
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private var lastErrorWasReadFailure = false
    @ObservationIgnored private var operationRevision: UInt64 = 0
    private let backend: any EnergyModeBackend

    init(backend: any EnergyModeBackend = SystemEnergyModeBackend()) {
        self.backend = backend
    }

    @ObservationIgnored private var monitoringTask: Task<Void, Never>?

    @ObservationIgnored private var monitoringInterval: TimeInterval?

    /// Keep mode state current at the same cadence as automatic power refreshes.
    func startMonitoring(interval: TimeInterval) {
        let interval = PowerMonitor.validatedInterval(interval)
        if monitoringTask != nil, monitoringInterval == interval { return }
        stopMonitoring()
        monitoringInterval = interval
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    deinit { monitoringTask?.cancel() }

    func refresh() async {
        guard !isBusy, !isRefreshing else { return }
        isRefreshing = true
        let revision = operationRevision
        defer { isRefreshing = false }
        do {
            let updated = try await backend.read()
            // A read started before a user action cannot overwrite its result.
            guard revision == operationRevision, !Task.isCancelled else { return }
            if settings != updated { settings = updated }
            if lastErrorWasReadFailure { errorMessage = nil }
            lastErrorWasReadFailure = false
        } catch {
            guard revision == operationRevision, !Task.isCancelled else { return }
            settings = [:]
            lastErrorWasReadFailure = true
            errorMessage = error.localizedDescription
        }
    }

    func select(_ mode: EnergyMode, source: EnergyPowerSource) async {
        guard !isBusy, let setting = settings[source], setting.mode != mode else { return }
        operationRevision &+= 1
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
