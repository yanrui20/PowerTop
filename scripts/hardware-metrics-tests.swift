import Foundation

actor HardwareFixture: SystemMetricsReading {
    func read(selection: SystemMetricSelection, forceSlow: Bool) async -> RawSystemMetrics {
        RawSystemMetrics(uptime: 1, memory: MemoryUsage.fromPages(active: 100, inactive: 50, speculative: 10,
            wired: 20, compressed: 30, purgeable: 5, fileBacked: 25, pageSize: 1_024, total: 300 * 1_024),
            hardware: .init(cpuTemperature: .init(averageCelsius: 42.5, maximumCelsius: 44, sensorCount: 2),
                            fans: [.init(index: 0, rpm: 0), .init(index: 1, rpm: 2500)]),
            disk: DiskUsage.resolve(total: 1000, available: 400, importantAvailable: 500))
    }
}

@main struct HardwareMetricsTests {
    static func near(_ actual: Double?, _ expected: Double) {
        precondition(actual != nil && abs(actual! - expected) < 0.001)
    }
    @MainActor static func main() async throws {
        near(SMCNumberDecoder.decode(type: "sp78", bytes: [0x2A, 0x80]), 42.5)
        near(SMCNumberDecoder.decode(type: "sp78", bytes: [0xFF, 0]), -1)
        near(SMCNumberDecoder.decode(type: "fpe2", bytes: [0x27, 0x10]), 2500)
        near(SMCNumberDecoder.decode(type: "fpe2", bytes: [0, 0]), 0)
        near(SMCNumberDecoder.decode(type: "ui8 ", bytes: [2]), 2)
        near(SMCNumberDecoder.decode(type: "ui16", bytes: [1, 0]), 256)
        near(SMCNumberDecoder.decode(type: "ui32", bytes: [0, 0, 1, 0]), 256)
        var float: Float = 45.25
        near(SMCNumberDecoder.decode(type: "flt ", bytes: withUnsafeBytes(of: &float) { Array($0) }), 45.25)
        float = .nan
        precondition(SMCNumberDecoder.decode(type: "flt ", bytes: withUnsafeBytes(of: &float) { Array($0) }) == nil)
        precondition(SMCNumberDecoder.decode(type: "flt ", bytes: [0, 0]) == nil)
        precondition(SMCNumberDecoder.decode(type: "unknown", bytes: [0]) == nil)
        let keys = HardwareSensorsReader.cpuTemperatureKeys(model: "Apple M5 Pro")
        precondition(keys.count == 18 && keys.contains("Tp00") && !keys.contains(where: { $0.hasPrefix("Tg") }))
        precondition(HardwareSensorsReader.cpuTemperatureKeys(model: "Apple M10").isEmpty)
        precondition(HardwareSensorsReader.cpuTemperatureKeys(model: "unknown").isEmpty)

        let raw = await HardwareFixture().read()
        near(raw.memory?.percent, 60)
        near(raw.memory?.percent(for: .lemon), 50)
        let disk = raw.disk!
        precondition(disk.availableBytes == 500 && disk.includesPurgeable)
        near(disk.usedPercent, 50)
        precondition(DiskUsage.resolve(total: 0, available: 0, importantAvailable: nil) == nil)
        precondition(DiskUsage.resolve(total: 1000, available: nil, importantAvailable: nil) == nil)
        precondition(DiskUsage.resolve(total: 1000, available: 400, importantAvailable: -1)?.availableBytes == 400)
        precondition(DiskUsage.resolve(total: 1000, available: 0, importantAvailable: nil)?.usedPercent == 100)
        precondition(DiskUsage.resolve(total: 1000, available: 400, importantAvailable: 1200)?.availableBytes == 1000)
        var accumulator = SystemMetricsAccumulator()
        let first = accumulator.consume(raw)
        near(first.hardware.cpuTemperature?.averageCelsius, 42.5)
        near(first.hardware.fans?[0].rpm, 0)
        precondition(first.disk?.totalBytes == 1000)

        let suite = "PowerTop.HardwareMetrics." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let metrics = SystemMetricsMonitor(reader: HardwareFixture())
        let monitor = PowerMonitor(defaults: defaults, systemMetrics: metrics)
        await metrics.refresh()
        precondition(!monitor.showTemperatureInMenuBar && !monitor.showFansInMenuBar && !monitor.showDiskInMenuBar)
        monitor.showCPUInMenuBar = false; monitor.showGPUInMenuBar = false; monitor.showNetworkInMenuBar = false
        precondition(monitor.menuBarPresentation.resources.map(\.top) == ["60%"])
        monitor.memoryAccounting = .lemon
        precondition(monitor.menuBarPresentation.resources.map(\.top) == ["50%"])
        monitor.showTemperatureInMenuBar = true; monitor.showFansInMenuBar = true; monitor.showDiskInMenuBar = true
        let items = monitor.menuBarPresentation.resources
        precondition(items.map(\.bottom) == ["MEM", "TEMP", "RPM", "DISK"])
        precondition(items[2].top == "2500" && items[3].top == "50%")
        let restored = PowerMonitor(defaults: defaults)
        precondition(restored.memoryAccounting == .lemon && restored.showTemperatureInMenuBar && restored.showFansInMenuBar && restored.showDiskInMenuBar)
        print("PASS: SMC numeric decoding, zero RPM, model-specific CPU mapping, dual memory accounting, disk capacity validation, persisted choices and menu values")
        if CommandLine.arguments.contains("--read-system") {
            let live = await SystemMetricsReader().read()
            let cpu = live.hardware.cpuTemperature
            print("LIVE CPU temperature=\(String(describing: cpu?.averageCelsius)) C, sensors=\(cpu?.sensorCount ?? 0), fans=\(live.hardware.fans?.map { String(describing: $0.rpm) } ?? []), disk=\(live.disk?.capacityText ?? "unavailable"), used=\(String(describing: live.disk?.usedPercent))%")
            print("LIVE memory: cache-adjusted=\(String(describing: live.memory?.percent))%, Lemon=\(String(describing: live.memory?.percent(for: .lemon)))%")
        }
    }
}
