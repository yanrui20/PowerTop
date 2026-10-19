import AppKit
import Foundation

actor ColorTestBackend: EnergyModeBackend {
    var mode = EnergyMode.low
    func read() async throws -> [EnergyPowerSource: EnergyModeSetting] {
        [.battery: .init(mode: mode, supportsHighPower: true),
         .adapter: .init(mode: .high, supportsHighPower: true)]
    }
    func setMode(_ mode: EnergyMode) { self.mode = mode }
    func apply(_ mode: EnergyMode, source: EnergyPowerSource, setting: EnergyModeSetting) async throws {
        precondition(source == .battery)
        self.mode = mode
    }
}

@main
struct StatusLayoutTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "PowerTop.LayoutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["showCPUInMenuBar", "showGPUInMenuBar", "showMemoryInMenuBar", "showNetworkInMenuBar"] {
            defaults.set(false, forKey: key) // Retain the original battery-only layout checks.
        }
        let backend = ColorTestBackend()
        let modes = EnergyModeController(backend: backend)
        let monitor = PowerMonitor(defaults: defaults, energyModes: modes)
        monitor.showPowerInMenuBar = true
        let controller = StatusItemController(monitor: monitor)
        try await Task.sleep(for: .milliseconds(200))
        if let widths = controller.menuBarLayoutWidths {
            precondition(widths.occupied <= widths.button + 1, "Closed status item must not reserve extra outer spacing")
            print("PASS closed menu bar: \(widths)")
        } else { preconditionFailure("Missing status item window") }
        // The panel remains closed throughout these color checks.
        modes.startMonitoring(interval: 5)
        try await Task.sleep(for: .milliseconds(150))
        precondition(monitor.menuBarPresentation.tint == .yellow)
        precondition(controller.testTextColor == nil, "Power text must keep the normal menu color")
        await backend.setMode(.high)
        try await Task.sleep(for: .milliseconds(5300))
        precondition(monitor.menuBarPresentation.tint == .white)
        precondition(controller.testTextColor == nil, "High power must not recolor power text")
        for (mode, color) in [(EnergyMode.low, NSColor.systemYellow), (.high, .white), (.automatic, nil)] as [(EnergyMode, NSColor?)] {
            await modes.select(mode, source: .battery)
            try await Task.sleep(for: .milliseconds(150))
            precondition(controller.testTextColor == nil)
            if let dir = ProcessInfo.processInfo.environment["POWERTOP_TEST_PREVIEW_DIR"] {
                try controller.saveButtonForTest(to: URL(fileURLWithPath: dir).appendingPathComponent("mode-\(mode.rawValue)-text.png"))
            }
            monitor.showPowerInMenuBar = false
            monitor.showBatteryInMenuBar = true
            try await Task.sleep(for: .milliseconds(150))
            precondition(controller.testImageIsTemplate == (color == nil))
            if let dir = ProcessInfo.processInfo.environment["POWERTOP_TEST_PREVIEW_DIR"] {
                try controller.saveButtonForTest(to: URL(fileURLWithPath: dir).appendingPathComponent("mode-\(mode.rawValue)-icon.png"))
            }
            monitor.showPowerInMenuBar = true
        }
        modes.stopMonitoring()
        print("PASS: only the battery changes mode color; other menu text stays normal")
        controller.showForLayoutTest()
        try await Task.sleep(for: .milliseconds(300))
        for (battery, power) in [(false, false), (true, false), (true, true), (false, true), (false, false), (true, false)] {
            monitor.showBatteryInMenuBar = battery
            monitor.showPowerInMenuBar = power
            try await Task.sleep(for: .milliseconds(300))
            let widths = controller.menuBarLayoutWidths!
            precondition(widths.occupied <= widths.button + 1, "Open status item must not reserve extra outer spacing")
            let bounds = controller.layoutTestAnchor
            let anchor = controller.layoutTestPositioningRect
            let button = controller.layoutTestButtonFrame
            let panel = controller.layoutTestPopoverFrame
            precondition(bounds.width > 0 && panel.width > 200)
            precondition(abs(bounds.midX - anchor.midX) < 1 && abs(bounds.width - anchor.width) < 1,
                         "Popover anchor must follow the status button after changing display options")
            precondition(button.midX >= panel.minX && button.midX <= panel.maxX,
                         "Popover must stay below its own menu bar item")
            print("PASS layout: battery=\(battery), power=\(power), button=\(button), panel=\(panel)")
            controller.closeForLayoutTest()
            controller.showForLayoutTest()
        }
        if let dir = ProcessInfo.processInfo.environment["POWERTOP_TEST_PREVIEW_DIR"] {
            for percent in [0, 9, 76, 100] {
                for mode in EnergyMode.allCases {
                    for (battery, power) in [(false, false), (true, false), (true, true), (false, true)] {
                        let presentation = MenuBarPresentation(available: true, percent: percent, charging: true, onAC: true,
                            showBattery: battery, showPower: power, powerText: "23W", mode: mode)
                        controller.showPresentationForTest(presentation)
                        try await Task.sleep(for: .milliseconds(150))
                        let widths = controller.menuBarLayoutWidths!
                        precondition(widths.occupied <= widths.button + 1, "Charging layout must not reserve extra outer spacing")
                        print("PASS charging layout: \(presentation.title), \(widths)")
                        let rect = controller.layoutTestAnchor
                        precondition(abs(rect.width - controller.layoutTestPositioningRect.width) < 1)
                        try controller.saveButtonForTest(to: URL(fileURLWithPath: dir).appendingPathComponent("charging-\(percent)-\(mode.rawValue)-\(battery)-\(power).png"))
                    }
                }
            }
        }
        controller.invalidate()
        print("PASS: repeated percentage/power changes and closing/reopening the panel")
    }
}
