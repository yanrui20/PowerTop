import Foundation
import Observation

@MainActor
@Observable
final class SystemMetricsMonitor {
    private(set) var snapshot: SystemMetricsSnapshot = .empty
    @ObservationIgnored private let reader: any SystemMetricsReading
    @ObservationIgnored private var accumulator = SystemMetricsAccumulator()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var interval: TimeInterval?
    private(set) var selection: SystemMetricSelection = .all

    init(reader: any SystemMetricsReading = SystemMetricsReader()) { self.reader = reader }
    deinit { task?.cancel() }

    func refresh(forceSlow: Bool = false) async {
        if forceSlow {
            let requestedGeneration = generation
            while reading {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard requestedGeneration == generation else { return }
            }
        }
        guard !reading, !selection.isEmpty else { return }
        reading = true
        let revision = generation
        defer { reading = false }
        let raw = await reader.read(selection: selection, forceSlow: forceSlow)
        guard revision == generation, !Task.isCancelled else { return }
        snapshot = accumulator.consume(raw)
    }

    func start(interval: TimeInterval, selection: SystemMetricSelection = .all, forceSlow: Bool = false) {
        let interval = selection == .disk ? max(SystemMetricsReader.diskInterval, PowerMonitor.validatedInterval(interval))
            : PowerMonitor.validatedInterval(interval)
        guard task == nil || self.interval != interval || self.selection != selection || forceSlow else { return }
        task?.cancel()
        generation &+= 1
        self.selection = selection
        self.interval = interval
        if selection.isEmpty { stop(); return }
        task = Task { [weak self] in
            // Let a cancelled in-flight read finish before acquiring the new selection.
            while self?.reading == true {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.refresh(forceSlow: forceSlow)
            // Two snapshots are needed for CPU and network rates. Bootstrap once
            // without making the user wait a potentially long configured interval.
            do { try await Task.sleep(for: .seconds(selection.needsRateBaseline ? min(1, interval) : interval)) } catch { return }
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        accumulator.reset()
        snapshot = .empty
    }
}
