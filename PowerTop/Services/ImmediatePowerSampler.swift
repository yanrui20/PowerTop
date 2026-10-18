import Foundation

enum ImmediateRefreshError: LocalizedError {
    case missingTimestamp, timedOut, unreadable
    var errorDescription: String? {
        switch self {
        case .missingTimestamp: return String(localized: "Cannot confirm a new system sample: update time is unavailable.")
        case .timedOut: return String(localized: "No new system sample within 10 seconds. Existing readings are shown.")
        case .unreadable: return String(localized: "Unable to refresh power readings.")
        }
    }
}

struct ImmediatePowerSampler {
    let request: @Sendable () async throws -> Void
    let readTimestamp: @Sendable () -> TimeInterval?
    var timeout: TimeInterval = 10
    var pollInterval: TimeInterval = 0.25

    func sample() async throws -> TimeInterval {
        try Task.checkCancellation()
        guard let before = readTimestamp() else { throw ImmediateRefreshError.missingTimestamp }
        try await request()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try Task.checkCancellation()
            if let after = readTimestamp(), after > before { return after }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            try await Task.sleep(nanoseconds: UInt64(max(0.001, pollInterval) * 1_000_000_000))
        } while true
        throw ImmediateRefreshError.timedOut
    }
}
