import Foundation
import Darwin

struct SystemMetricSelection: OptionSet, Sendable {
    let rawValue: Int
    static let cpu = Self(rawValue: 1 << 0)
    static let gpu = Self(rawValue: 1 << 1)
    static let memory = Self(rawValue: 1 << 2)
    static let network = Self(rawValue: 1 << 3)
    static let temperature = Self(rawValue: 1 << 4)
    static let fans = Self(rawValue: 1 << 5)
    static let disk = Self(rawValue: 1 << 6)
    static let all: Self = [.cpu, .gpu, .memory, .network, .temperature, .fans, .disk]
    var needsRateBaseline: Bool { !intersection([.cpu, .network]).isEmpty }
}

/// Cache unavailable results too, so an unsupported slow metric cannot cause retries every tick.
struct SlowMetricCache<Value> {
    private var sampledAt: TimeInterval?
    private var cached: Value?
    mutating func value(at now: TimeInterval, interval: TimeInterval, force: Bool = false,
                        load: () -> Value?) -> Value? {
        if force || sampledAt == nil || now < sampledAt! || now - sampledAt! >= interval {
            cached = load(); sampledAt = now
        }
        return cached
    }
}

struct CPUTicks: Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func utilization(since old: CPUTicks) -> Double? {
        // Kernel counters are UInt32; wrapping subtraction handles rollover.
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        let total = busy + UInt64(idle &- old.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

struct MemoryUsage: Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    var lemonUsedBytes: UInt64?
    func usedBytes(for accounting: MemoryAccounting) -> UInt64 { accounting == .lemon ? (lemonUsedBytes ?? usedBytes) : usedBytes }
    func percent(for accounting: MemoryAccounting) -> Double { totalBytes > 0 ? Double(usedBytes(for: accounting)) / Double(totalBytes) * 100 : 0 }
    var percent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }

    static func fromPages(active: UInt32, inactive: UInt32, speculative: UInt32,
                          wired: UInt32, compressed: UInt32, purgeable: UInt32,
                          fileBacked: UInt32, pageSize: UInt64, total: UInt64) -> MemoryUsage? {
        guard pageSize > 0, total > 0 else { return nil }
        let resident = Double(active) + Double(inactive) + Double(speculative) + Double(wired) + Double(compressed)
        let reclaimable = Double(purgeable) + Double(fileBacked)
        let used = min(Double(total), max(0, resident - reclaimable) * Double(pageSize))
        let lemon = min(Double(total), (Double(active) + Double(wired) + Double(compressed)) * Double(pageSize))
        return MemoryUsage(usedBytes: UInt64(used), totalBytes: total, lemonUsedBytes: UInt64(lemon))
    }
}

struct NetworkInterfaceCounters: Sendable {
    let type: UInt8
    let received: UInt64
    let sent: UInt64
}

struct NetworkCounters: Sendable {
    let interface: String
    let received: UInt64
    let sent: UInt64

    static func aggregate(_ interfaces: [NetworkInterfaceCounters]) -> Self {
        let physicalTypes: Set<UInt8> = [UInt8(IFT_ETHER), UInt8(IFT_PPP), UInt8(IFT_MODEM), UInt8(IFT_CELLULAR)]
        let excludedFallbackTypes: Set<UInt8> = [UInt8(IFT_LOOP), UInt8(IFT_GIF), UInt8(IFT_STF), UInt8(IFT_PKTAP)]
        func sum(_ selected: [NetworkInterfaceCounters]) -> (received: UInt64, sent: UInt64) {
            selected.reduce((UInt64(0), UInt64(0))) { ($0.0 &+ $1.received, $0.1 &+ $1.sent) }
        }
        let physical = sum(interfaces.filter { physicalTypes.contains($0.type) })
        // Lemon's fallback checks cumulative receive bytes, not the current download rate.
        let total = physical.received == 0
            ? sum(interfaces.filter { !excludedFallbackTypes.contains($0.type) }) : physical
        return .init(interface: "aggregate", received: total.received, sent: total.sent)
    }
}

struct RawSystemMetrics: Sendable {
    let uptime: TimeInterval
    var cpu: CPUTicks?
    var gpuPercent: Double?
    var memory: MemoryUsage?
    var network: NetworkCounters?
    var hardware: HardwareReadings = .init()
    var disk: DiskUsage?
}

struct SystemMetricsSnapshot: Sendable {
    var cpuPercent: Double?
    var gpuPercent: Double?
    var memory: MemoryUsage?
    var interface: String?
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var hardware: HardwareReadings = .init()
    var disk: DiskUsage?
    static let empty = SystemMetricsSnapshot()

    static func percentText(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }
    static func rateText(_ value: Double?) -> String {
        guard var value, value.isFinite, value >= 0 else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var unit = 0
        while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
    var memoryText: String { memoryText(using: .cacheAdjusted) }
    func memoryText(using accounting: MemoryAccounting) -> String {
        guard let memory else { return "—" }
        return String(format: "%.1f / %.0f GiB", Double(memory.usedBytes(for: accounting)) / 1_073_741_824, Double(memory.totalBytes) / 1_073_741_824)
    }
}

struct SystemMetricsAccumulator {
    private var previous: RawSystemMetrics?
    mutating func reset() { previous = nil }

    mutating func consume(_ raw: RawSystemMetrics) -> SystemMetricsSnapshot {
        defer { previous = raw }
        var result = SystemMetricsSnapshot(gpuPercent: raw.gpuPercent, memory: raw.memory,
                                           interface: raw.network?.interface, hardware: raw.hardware, disk: raw.disk)
        guard let old = previous, raw.uptime.isFinite, old.uptime.isFinite,
              raw.uptime > old.uptime else { return result }
        if let cpu = raw.cpu, let priorCPU = old.cpu { result.cpuPercent = cpu.utilization(since: priorCPU) }
        if let network = raw.network, let priorNetwork = old.network,
           network.interface == priorNetwork.interface {
            let elapsed = raw.uptime - old.uptime
            // Match Lemon: each direction is independent; equal/decreased counters yield zero.
            result.downloadBytesPerSecond = network.received > priorNetwork.received
                ? Double(network.received - priorNetwork.received) / elapsed : 0
            result.uploadBytesPerSecond = network.sent > priorNetwork.sent
                ? Double(network.sent - priorNetwork.sent) / elapsed : 0
        }
        return result
    }
}
