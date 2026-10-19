import Foundation

enum MemoryAccounting: String, CaseIterable {
    case cacheAdjusted, lemon
    var title: String {
        self == .lemon ? String(localized: "Active + wired + compressed") : String(localized: "Subtract reclaimable and file cache")
    }
    var explanation: String {
        self == .lemon
            ? String(localized: "Active + wired (not pageable) + compressed memory, divided by total physical memory.")
            : String(localized: "Active + inactive + speculative + wired + compressed, minus purgeable and file-backed memory, divided by total physical memory.")
    }
}

struct CPUTemperature: Sendable {
    let averageCelsius: Double
    let maximumCelsius: Double
    let sensorCount: Int
}
struct FanSpeed: Sendable {
    let index: Int
    let rpm: Double?
}
struct HardwareReadings: Sendable {
    var cpuTemperature: CPUTemperature?
    var fans: [FanSpeed]?
}

struct DiskUsage: Sendable {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let includesPurgeable: Bool
    var usedPercent: Double { Double(totalBytes - availableBytes) / Double(totalBytes) * 100 }
    var capacityText: String {
        String(format: String(localized: "%.1f GB available / %.1f GB total"), Double(availableBytes) / 1e9, Double(totalBytes) / 1e9)
    }
    static func resolve(total: Int64?, available: Int64?, importantAvailable: Int64?) -> DiskUsage? {
        guard let total, total > 0 else { return nil }
        let important = importantAvailable.flatMap { $0 >= 0 ? $0 : nil }
        let ordinary = available.flatMap { $0 >= 0 ? $0 : nil }
        guard let value = important ?? ordinary else { return nil }
        return DiskUsage(totalBytes: UInt64(total), availableBytes: UInt64(min(total, value)),
                         includesPurgeable: important.map { $0 > (ordinary ?? $0) } ?? false)
    }
}
