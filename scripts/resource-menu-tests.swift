import Foundation
import AppKit

actor MenuMetricsReader: SystemMetricsReading {
    private var count = 0
    func readCount() -> Int { count }
    func read(selection: SystemMetricSelection, forceSlow: Bool) async -> RawSystemMetrics {
        count += 1
        return .init(uptime: Double(count), cpu: .init(user: UInt32(count * 20), system: 0, idle: UInt32(count * 80), nice: 0),
            gpuPercent: 42, memory: .init(usedBytes: 8, totalBytes: 16),
            network: .init(interface: "en0", received: UInt64(count * 2_000), sent: UInt64(count * 1_000)))
    }
}
final class PowerRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func request() { lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct ResourceMenuTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "PowerTop.ResourceMenuTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(15.0, forKey: "powerRefreshInterval")
        let reader = MenuMetricsReader()
        let metrics = SystemMetricsMonitor(reader: reader)
        let requests = PowerRequests()
        let monitor = PowerMonitor(defaults: defaults, systemMetrics: metrics, immediateSampler: .init(
            request: { requests.request(); throw EnergyModeError.unavailable }, readTimestamp: { 100 }))
        precondition(monitor.updateInterval == 15 && monitor.resourceRefreshInterval == 2)
        let paths: [ReferenceWritableKeyPath<PowerMonitor, Bool>] = [\.showCPUInMenuBar, \.showGPUInMenuBar, \.showMemoryInMenuBar, \.showNetworkInMenuBar]
        monitor.showBatteryInMenuBar = false
        monitor.showPowerInMenuBar = false
        let controller = StatusItemController(monitor: monitor)
        try await Task.sleep(for: .milliseconds(100))
        controller.showForLayoutTest()
        for mask in 0..<16 {
            for (i, path) in paths.enumerated() { monitor[keyPath: path] = mask & (1 << i) != 0 }
            try await Task.sleep(for: .milliseconds(80))
            let presentation = monitor.menuBarPresentation
            precondition(presentation.resources.count == mask.nonzeroBitCount)
            precondition(presentation.symbol == (mask == 0 ? "battery.50" : nil))
            let widths = controller.menuBarLayoutWidths!
            precondition(widths.occupied <= widths.button + 1)
            precondition(widths.button <= 150, "Resource-only status item must stay compact")
            precondition(abs(controller.layoutTestAnchor.width - controller.layoutTestPositioningRect.width) < 1)
        }
        let restored = PowerMonitor(defaults: defaults)
        for path in paths { precondition(restored[keyPath: path]) }
        monitor.showCPUInMenuBar = false
        let oneOff = PowerMonitor(defaults: defaults)
        precondition(!oneOff.showCPUInMenuBar && oneOff.showGPUInMenuBar && oneOff.showMemoryInMenuBar && oneOff.showNetworkInMenuBar)

        try await Task.sleep(for: .milliseconds(200))
        let examples: [MenuBarResourceItem] = [.percent(8, label: "CPU"), .percent(12, label: "GPU"), .percent(69, label: "MEM"), .network(upload: 8200, download: 3_600_000)]
        let maximums: [MenuBarResourceItem] = [.percent(100, label: "CPU"), .percent(100, label: "GPU"), .percent(100, label: "MEM"), .network(upload: 999_000, download: 999_000_000)]
        precondition(zip(examples, maximums).allSatisfy { $0.width == $1.width }, "Ordinary value changes should not resize columns")
        precondition(MenuBarResourceItem.compactRate(1_500_000) == "1.5M/s")
        for mode in EnergyMode.allCases {
            let presentation = MenuBarPresentation(available: true, percent: 100, charging: true, onAC: true,
                showBattery: true, showPower: true, powerText: "23W", mode: mode, resources: examples)
            controller.showPresentationForTest(presentation)
            try await Task.sleep(for: .milliseconds(80))
            let widths = controller.menuBarLayoutWidths!
            precondition(widths.occupied <= widths.button + 1 && widths.button <= 210, "Unexpected native width: \(widths); image=\(presentation.compactStatusImage()!.size)")
            precondition(controller.testImageIsTemplate == false)
            precondition(abs(widths.button - (presentation.compactStatusImage()!.size.width + 4)) <= 1,
                         "Appearance callbacks must preserve the current presentation")
            if let dir = ProcessInfo.processInfo.environment["POWERTOP_TEST_PREVIEW_DIR"] {
                try controller.saveButtonForTest(to: URL(fileURLWithPath: dir).appendingPathComponent("resources-mode-\(mode.rawValue).png"))
            }
            print("PASS resources menu mode=\(mode.rawValue): button=\(widths.button), occupied=\(widths.occupied)")
        }
        // External menu-bar replicas must not turn appearance callbacks into redraw loops.
        controller.testSetAppearance(.aqua)
        try await Task.sleep(for: .milliseconds(150))
        let beforeAppearanceStorm = controller.testRenderCount
        for _ in 0..<1000 { controller.testAppearanceNotification() }
        try await Task.sleep(for: .milliseconds(150))
        precondition(controller.testRenderCount == beforeAppearanceStorm, "Identical appearance notifications must not redraw")
        controller.testSetAppearance(.darkAqua)
        try await Task.sleep(for: .milliseconds(150))
        let darkRenderCount = controller.testRenderCount
        precondition(darkRenderCount == beforeAppearanceStorm + 1, "Actual theme changes must redraw exactly once")
        for _ in 0..<1000 { controller.testAppearanceNotification() }
        try await Task.sleep(for: .milliseconds(150))
        precondition(controller.testRenderCount == darkRenderCount)
        let bitmap = MenuBarPresentation(available: true, percent: 66, charging: true, onAC: true,
            showBattery: true, showPower: true, powerText: "25W", resources: examples).compactStatusImage()!
        precondition(bitmap.representations.count == 2 && bitmap.representations.allSatisfy { $0 is NSBitmapImageRep })
        controller.invalidate()

        monitor.updateInterval = 300
        monitor.resourceRefreshInterval = 1
        monitor.start()
        try await Task.sleep(for: .milliseconds(2200))
        let fastCount = await reader.readCount()
        precondition(fastCount >= 3 && requests.value() == 0, "Fast resources must not trigger battery sampling")
        monitor.updateInterval = 250
        let before = await reader.readCount()
        try await Task.sleep(for: .milliseconds(3200))
        let after = await reader.readCount()
        precondition(after >= before + 3, "Changing battery cadence must not slow resource updates")
        precondition(monitor.resourceRefreshInterval == 1 && requests.value() == 0)
        monitor.resourceRefreshInterval = 120
        precondition(monitor.updateInterval == 250)
        let saved = PowerMonitor(defaults: defaults)
        precondition(saved.resourceRefreshInterval == 120 && saved.updateInterval == 250)
        monitor.stop()
        print("PASS: 16 independent toggle combinations, persisted settings, stable compact columns, native anchoring and independent resource/battery scheduling")
    }
}
