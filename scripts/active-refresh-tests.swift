import Foundation

final class SamplingFixture: @unchecked Sendable {
    let lock = NSLock()
    var requests = 0
    var reads = 0
    var missing = false
    var advances = true
    func request() { lock.lock(); requests += 1; lock.unlock() }
    func stamp() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if missing { return nil }
        return advances && reads >= 3 ? 101 : 100
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
}

@main struct ActiveRefreshTests {
    @MainActor static func main() async throws {
        precondition(SystemBatterySampling.requestWasAccepted(1))
        precondition(SystemBatterySampling.requestWasAccepted(0))
        precondition(!SystemBatterySampling.requestWasAccepted(-1))
        let fixture = SamplingFixture()
        let sampler = ImmediatePowerSampler(request: { fixture.request() }, readTimestamp: { fixture.stamp() }, timeout: 0.1, pollInterval: 0.001)
        let updated = try await sampler.sample()
        precondition(updated == 101 && fixture.requestCount == 1)

        let unchanged = SamplingFixture(); unchanged.advances = false
        let timeout = ImmediatePowerSampler(request: { unchanged.request() }, readTimestamp: { unchanged.stamp() }, timeout: 0.02, pollInterval: 0.001)
        do { _ = try await timeout.sample(); preconditionFailure("Same timestamp is not a new sample") }
        catch ImmediateRefreshError.timedOut { }
        precondition(unchanged.requestCount == 1)

        let missing = SamplingFixture(); missing.missing = true
        let noStamp = ImmediatePowerSampler(request: { missing.request() }, readTimestamp: { missing.stamp() })
        do { _ = try await noStamp.sample(); preconditionFailure("Cannot confirm freshness without a baseline") }
        catch ImmediateRefreshError.missingTimestamp { }
        precondition(missing.requestCount == 0)

        let failure = ImmediatePowerSampler(request: { throw EnergyModeError.unavailable }, readTimestamp: { 100 })
        do { _ = try await failure.sample(); preconditionFailure("Request failure must propagate") }
        catch EnergyModeError.unavailable { }

        let suite = "PowerTop.PassiveReadTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let passiveFixture = SamplingFixture()
        let monitor = PowerMonitor(defaults: defaults, immediateSampler: .init(
            request: { passiveFixture.request() }, readTimestamp: { passiveFixture.stamp() },
            timeout: 0.1, pollInterval: 0.001))
        for _ in 0..<3 { monitor.refreshNow() }
        monitor.updateInterval = 5
        monitor.refreshNow()
        precondition(passiveFixture.requestCount == 0, "Ordinary reads and interval changes must not request hardware sampling")
        do { _ = try await monitor.refreshImmediately() }
        catch ImmediateRefreshError.unreadable { } // CI may not have a built-in battery.
        precondition(passiveFixture.requestCount == 1)
        precondition(!monitor.isRequestingSystemSample)
        let scheduledFixture = SamplingFixture()
        let scheduled = PowerMonitor(defaults: defaults, immediateSampler: .init(
            request: {
                scheduledFixture.request()
                try await Task.sleep(for: .milliseconds(50))
            }, readTimestamp: { Double(100 + scheduledFixture.requestCount) },
            timeout: 0.1, pollInterval: 0.001))
        scheduled.updateInterval = 300
        scheduled.start()
        let tick = Task { await scheduled.testScheduledRefresh() }
        try await Task.sleep(for: .milliseconds(5))
        precondition(scheduled.isRequestingSystemSample)
        await scheduled.testScheduledRefresh() // overlapping timer tick must skip
        scheduled.testPowerSourceEvent() // sampling notifications must stay passive
        let manual = Task { try? await scheduled.refreshImmediately() }
        await tick.value
        _ = await manual.value
        precondition(scheduledFixture.requestCount == 1, "Timer/manual requests must coalesce")
        precondition(!scheduled.isRequestingSystemSample)
        scheduled.testSleep()
        await scheduled.testScheduledRefresh()
        precondition(scheduledFixture.requestCount == 1, "Sleep must pause sampling")
        scheduled.testWake()
        await scheduled.testScheduledRefresh()
        precondition(scheduledFixture.requestCount == 2, "Wake must resume scheduling")
        let cancelled = Task { await scheduled.testScheduledRefresh() }
        try await Task.sleep(for: .milliseconds(5))
        scheduled.testSleep()
        await cancelled.value
        precondition(!scheduled.isRequestingSystemSample)
        precondition(scheduled.samplingError == nil, "Cancellation is not a sampling failure")
        scheduled.testWake()
        let stopped = Task { await scheduled.testScheduledRefresh() }
        try await Task.sleep(for: .milliseconds(5))
        scheduled.stop()
        await stopped.value
        let countAtStop = scheduledFixture.requestCount
        await scheduled.testScheduledRefresh()
        scheduled.testPowerSourceEvent()
        scheduled.testWake()
        await scheduled.testScheduledRefresh()
        precondition(scheduledFixture.requestCount == countAtStop, "Stopped monitor must not restart")
        precondition(!scheduled.isRequestingSystemSample)

        let beforeTimer = scheduledFixture.requestCount
        scheduled.updateInterval = 1
        scheduled.start()
        try await Task.sleep(for: .milliseconds(1250))
        scheduled.stop()
        precondition(scheduledFixture.requestCount == beforeTimer + 1, "Real Timer must request sampling")

        let failed = PowerMonitor(defaults: defaults, immediateSampler: failure)
        failed.updateInterval = 300
        failed.start()
        await failed.testScheduledRefresh()
        precondition(failed.samplingError != nil && !failed.isRequestingSystemSample)
        failed.stop()
        print("PASS: fresh timestamps, timeout/missing/error paths, active timer, manual coalescing, passive notifications, sleep/stop cancellation and visible scheduled errors")
    }
}
