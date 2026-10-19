import Foundation
import AppKit

actor DemandFixture: SystemMetricsReading {
    struct Call: Sendable { let selection: SystemMetricSelection; let forced: Bool }
    private var calls: [Call] = []
    func history() -> [Call] { calls }
    func read(selection: SystemMetricSelection, forceSlow: Bool) async -> RawSystemMetrics {
        calls.append(.init(selection: selection, forced: forceSlow))
        let n = UInt32(calls.count)
        return .init(uptime: Double(n), cpu: selection.contains(.cpu) ? .init(user: n * 10, system: 0, idle: n * 90, nice: 0) : nil,
            network: selection.contains(.network) ? .init(interface: "en0", received: UInt64(n) * 100, sent: UInt64(n) * 50) : nil)
    }
}
actor QuietModes: EnergyModeBackend {
    func read() async throws -> [EnergyPowerSource: EnergyModeSetting] { [:] }
    func apply(_ mode: EnergyMode, source: EnergyPowerSource, setting: EnergyModeSetting) async throws {}
}

@main struct DemandReadingTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let fixture = DemandFixture()
        let resources = SystemMetricsMonitor(reader: fixture)
        let suite = "PowerTop.DemandTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(300.0, forKey: "powerRefreshInterval")
        defaults.set(2.0, forKey: "systemResourcesRefreshInterval")
        let monitor = PowerMonitor(defaults: defaults, energyModes: EnergyModeController(backend: QuietModes()), systemMetrics: resources)
        for item in [MenuBarItemKind.gpu, .memory, .network, .temperature, .fans, .disk] { monitor.setMenuBarItem(item, enabled: false) }
        precondition(monitor.resourceSelection == .cpu)
        monitor.start()
        try await Task.sleep(for: .milliseconds(1200))
        var calls = await fixture.history()
        precondition(calls.count == 2 && calls.allSatisfy { $0.selection == .cpu })
        precondition(resources.snapshot.cpuPercent == 10)
        precondition(monitor.batteryCellReadCount == 0)
        monitor.isPopoverVisible = true
        try await Task.sleep(for: .milliseconds(100))
        calls = await fixture.history()
        precondition(calls.last?.selection == .all && calls.last?.forced == true)
        monitor.isPopoverVisible = false
        try await Task.sleep(for: .milliseconds(100))
        precondition(resources.selection == .cpu)
        monitor.showCPUInMenuBar = false
        let idleCount = await fixture.history().count
        try await Task.sleep(for: .milliseconds(1200))
        let idleAfter = await fixture.history().count
        precondition(idleCount == idleAfter && resources.selection.isEmpty, "No visible resources must mean no polling")
        monitor.showDiskInMenuBar = true
        try await Task.sleep(for: .milliseconds(100))
        let diskCount = await fixture.history().count
        try await Task.sleep(for: .milliseconds(1200))
        let diskAfter = await fixture.history().count
        precondition(diskAfter == diskCount && resources.selection == .disk, "Disk-only view must not run at the fast resource interval")
        monitor.showNetworkInMenuBar = true
        try await Task.sleep(for: .milliseconds(1200))
        precondition(resources.snapshot.downloadBytesPerSecond == 100)
        precondition(monitor.updateInterval == 300 && monitor.resourceRefreshInterval == 2)
        let status = StatusItemController(monitor: monitor)
        try await Task.sleep(for: .milliseconds(100))
        precondition(status.testToolTip == nil)
        status.openDetails()
        precondition(monitor.isBatteryDetailsVisible)
        let cellReads = monitor.batteryCellReadCount
        if monitor.isDataAvailable { precondition(cellReads > 0) }
        status.closeDetailsForTest()
        precondition(!monitor.isBatteryDetailsVisible)
        monitor.refreshNow()
        precondition(monitor.batteryCellReadCount == cellReads, "Closed details must not enumerate battery cells")
        status.invalidate(); monitor.stop()

        var slow = SlowMetricCache<Int>()
        var diskReads = 0
        for time in stride(from: 0.0, to: 60.0, by: 2) {
            _ = slow.value(at: time, interval: 60) { diskReads += 1; return diskReads }
        }
        precondition(diskReads == 1)
        _ = slow.value(at: 60, interval: 60) { diskReads += 1; return diskReads }
        _ = slow.value(at: 61, interval: 60, force: true) { diskReads += 1; return diskReads }
        precondition(diskReads == 3)
        var missing = SlowMetricCache<Int>()
        var missingReads = 0
        for time in 0..<30 { _ = missing.value(at: Double(time), interval: 60) { missingReads += 1; return nil } }
        precondition(missingReads == 1)
        var metadata = BatteryMetadataCache()
        var dateReads = 0
        for _ in 0..<30 {
            _ = metadata.read(properties: ["Serial": "battery-a", "DeviceName": "test"]) { _ in dateReads += 1; return "2026-01-01" }
        }
        precondition(dateReads == 1)
        _ = metadata.read(properties: ["Serial": "battery-b", "DeviceName": "test"]) { _ in dateReads += 1; return "2026-02-01" }
        precondition(dateReads == 2, "Replacing battery identity invalidates cached metadata")
        let reader = SystemMetricsReader()
        let cpuOnly = await reader.read(selection: .cpu, forceSlow: false)
        precondition(cpuOnly.cpu != nil && cpuOnly.gpuPercent == nil && cpuOnly.memory == nil && cpuOnly.network == nil && cpuOnly.disk == nil && cpuOnly.hardware.cpuTemperature == nil && cpuOnly.hardware.fans == nil)
        print("PASS: visible-only reads, no polling when hidden, disk-only slow schedule, open/manual slow refresh, CPU/network warmup, static metadata caching, details lifetime and no tooltip")
    }
}
