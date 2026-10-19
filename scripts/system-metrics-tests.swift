import Foundation

actor MetricsFixture: SystemMetricsReading {
    private var count = 0
    private var held: CheckedContinuation<Void, Never>?
    private var holdNext = false
    func hold() { holdNext = true }
    func isHeld() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }
    func readCount() -> Int { count }
    func read(selection: SystemMetricSelection, forceSlow: Bool) async -> RawSystemMetrics {
        count += 1
        let n = count
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
        return RawSystemMetrics(uptime: Double(n), cpu: .init(user: UInt32(n * 10), system: 0, idle: UInt32(n * 90), nice: 0),
            gpuPercent: 20, memory: .init(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000),
            network: .init(interface: "en0", received: UInt64(n * 1_000), sent: UInt64(n * 500)))
    }
}

@main struct SystemMetricsTests {
    static func near(_ a: Double?, _ b: Double) {
        precondition(a != nil && abs(a! - b) < 0.001, "\(String(describing: a)) != \(b)")
    }
    @MainActor static func main() async throws {
        var accumulator = SystemMetricsAccumulator()
        let first = RawSystemMetrics(uptime: 10, cpu: .init(user: 10, system: 10, idle: 80, nice: 0),
            gpuPercent: 0, memory: nil, network: .init(interface: "en0", received: 5_000_000_000, sent: 6_000_000_000))
        let initial = accumulator.consume(first)
        precondition(initial.cpuPercent == nil && initial.downloadBytesPerSecond == nil)
        near(initial.gpuPercent, 0)
        let second = RawSystemMetrics(uptime: 12, cpu: .init(user: 25, system: 15, idle: 160, nice: 0),
            gpuPercent: nil, memory: nil, network: .init(interface: "en0", received: 5_000_002_000, sent: 6_000_001_000))
        let delta = accumulator.consume(second)
        near(delta.cpuPercent, 20); near(delta.downloadBytesPerSecond, 1_000); near(delta.uploadBytesPerSecond, 500)
        precondition(delta.gpuPercent == nil)
        var next = RawSystemMetrics(uptime: 14, network: .init(interface: "en1", received: 50_000_000_000, sent: 10))
        precondition(accumulator.consume(next).downloadBytesPerSecond == nil, "Interface changes must not spike")
        next = RawSystemMetrics(uptime: 16, network: .init(interface: "en1", received: 1, sent: 1))
        near(accumulator.consume(next).downloadBytesPerSecond, 0)
        next = RawSystemMetrics(uptime: 18, network: .init(interface: "en1", received: 1, sent: 1))
        near(accumulator.consume(next).downloadBytesPerSecond, 0)
        precondition(accumulator.consume(next).downloadBytesPerSecond == nil, "Zero elapsed time cannot yield a rate")
        // Sum the same interface types as Lemon, including inactive interfaces' counters.
        let physical = NetworkCounters.aggregate([
            .init(type: 6, received: 100, sent: 10), .init(type: 6, received: 200, sent: 20),
            .init(type: 0x17, received: 300, sent: 30), .init(type: 0x30, received: 400, sent: 40),
            .init(type: 0xff, received: 500, sent: 50), .init(type: 1, received: 9000, sent: 9000),
            .init(type: 0x18, received: 9000, sent: 9000)])
        precondition(physical.received == 1500 && physical.sent == 150)
        let fallback = NetworkCounters.aggregate([
            .init(type: 6, received: 0, sent: 10), .init(type: 1, received: 200, sent: 20),
            .init(type: 0xd1, received: 300, sent: 30),
            .init(type: 0x18, received: 999, sent: 999), .init(type: 0x37, received: 999, sent: 999),
            .init(type: 0x39, received: 999, sent: 999), .init(type: 0xfe, received: 999, sent: 999)])
        precondition(fallback.received == 500 && fallback.sent == 60)
        let accumulated = NetworkCounters.aggregate([.init(type: 6, received: 1, sent: 0), .init(type: 1, received: 999, sent: 999)])
        precondition(accumulated.received == 1 && accumulated.sent == 0, "Fallback uses cumulative receive bytes, not zero current traffic")
        let large = NetworkCounters.aggregate([.init(type: 6, received: 5_000_000_000, sent: 6_000_000_000), .init(type: 6, received: 7_000_000_000, sent: 8_000_000_000)])
        precondition(large.received == 12_000_000_000 && large.sent == 14_000_000_000)
        precondition(NetworkCounters.aggregate([]).received == 0)
        var independentRates = SystemMetricsAccumulator()
        _ = independentRates.consume(.init(uptime: 1, network: .init(interface: "aggregate", received: 100, sent: 100)))
        let resetOneSide = independentRates.consume(.init(uptime: 3, network: .init(interface: "aggregate", received: 50, sent: 120)))
        near(resetOneSide.downloadBytesPerSecond, 0); near(resetOneSide.uploadBytesPerSecond, 10)
        accumulator.reset()
        precondition(accumulator.consume(second).cpuPercent == nil)
        let wrapped = CPUTicks(user: 5, system: 0, idle: 110, nice: 0)
        near(wrapped.utilization(since: .init(user: UInt32.max - 4, system: 0, idle: 100, nice: 0)), 50)
        let memory = MemoryUsage.fromPages(active: 100, inactive: 50, speculative: 10,
            wired: 20, compressed: 30, purgeable: 5, fileBacked: 25, pageSize: 16_384, total: 10_000_000)!
        precondition(memory.usedBytes == 180 * 16_384)
        let bounded = MemoryUsage.fromPages(active: 100, inactive: 0, speculative: 0,
            wired: 0, compressed: 0, purgeable: 0, fileBacked: 0, pageSize: 16_384, total: 1_000)!
        precondition(bounded.usedBytes == 1_000)
        precondition(SystemMetricsSnapshot.rateText(1_500_000) == "1.5 MB/s")
        precondition(SystemMetricsSnapshot.rateText(nil) == "—")

        let fixture = MetricsFixture()
        let monitor = SystemMetricsMonitor(reader: fixture)
        monitor.start(interval: 300)
        try await Task.sleep(for: .milliseconds(1200))
        let bootstrapped = await fixture.readCount()
        precondition(bootstrapped == 2, "Initial rates need a prompt second reading")
        near(monitor.snapshot.cpuPercent, 10)
        near(monitor.snapshot.downloadBytesPerSecond, 1_000)
        monitor.start(interval: 1)
        try await Task.sleep(for: .milliseconds(1200))
        let changed = await fixture.readCount()
        precondition(changed == 4, "Interval updates must replace the previous task")
        monitor.stop()
        precondition(monitor.snapshot.cpuPercent == nil)
        try await Task.sleep(for: .milliseconds(1100))
        let stopped = await fixture.readCount()
        precondition(stopped == changed, "Stopped monitors cannot keep polling")
        await fixture.hold()
        let pending = Task { await monitor.refresh() }
        while !(await fixture.isHeld()) { await Task.yield() }
        monitor.stop()
        await fixture.release()
        await pending.value
        precondition(monitor.snapshot.gpuPercent == nil, "A late read cannot publish after sleep/stop")
        await fixture.hold()
        let ordinary = Task { await monitor.refresh() }
        while !(await fixture.isHeld()) { await Task.yield() }
        let forced = Task { await monitor.refresh(forceSlow: true) }
        await Task.yield()
        let beforeForced = await fixture.readCount()
        await fixture.release()
        await ordinary.value; await forced.value
        let afterForced = await fixture.readCount()
        precondition(afterForced == beforeForced + 1, "A manual slow refresh must not be lost behind an in-flight read")
        print("PASS: CPU deltas/rollover, 64-bit network counters, interface changes/reset/idle, memory accounting, warmup, interval changes and stop cancellation")

        if CommandLine.arguments.contains("--read-system") {
            let reader = SystemMetricsReader()
            var live = SystemMetricsAccumulator()
            _ = live.consume(await reader.read())
            try await Task.sleep(for: .seconds(1))
            let snapshot = live.consume(await reader.read())
            print("LIVE CPU=\(SystemMetricsSnapshot.percentText(snapshot.cpuPercent)), GPU=\(SystemMetricsSnapshot.percentText(snapshot.gpuPercent)), memory=\(snapshot.memoryText), interface=\(snapshot.interface ?? "unavailable"), down=\(SystemMetricsSnapshot.rateText(snapshot.downloadBytesPerSecond)), up=\(SystemMetricsSnapshot.rateText(snapshot.uploadBytesPerSecond))")
            precondition(snapshot.cpuPercent != nil && snapshot.memory != nil, "CPU and memory must be readable on this Mac")
        }
    }
}
