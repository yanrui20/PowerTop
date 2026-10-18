import Foundation

enum PowerReadingSource: Equatable {
    case systemLoad, systemPowerIn, batteryPower
    case instantCurrent, averageCurrent, adapterCurrent, powerBalance, batteryEstimate
    case disconnected, transition, unavailable

    var label: String {
        switch self {
        case .systemLoad: return String(localized: "Read: SystemLoad")
        case .systemPowerIn: return String(localized: "Read: SystemPowerIn")
        case .batteryPower: return String(localized: "Read: BatteryPower")
        case .instantCurrent: return String(localized: "Calc: Instant I × V")
        case .averageCurrent: return String(localized: "Calc: Average I × V")
        case .adapterCurrent: return String(localized: "Calc: Adapter I × V")
        case .powerBalance: return String(localized: "Estimate: power balance")
        case .batteryEstimate: return String(localized: "Estimate: battery output")
        case .disconnected: return String(localized: "State: no AC input")
        case .transition: return String(localized: "Source: settling")
        case .unavailable: return String(localized: "Source: unavailable")
        }
    }

    var hasValue: Bool { self != .unavailable && self != .transition }

    func formattedPower(_ value: Double) -> String {
        hasValue ? String(format: "%.1f W", value) : "—"
    }

    var detail: String {
        switch self {
        case .systemLoad: return "PowerTelemetryData.SystemLoad ÷ 1000"
        case .systemPowerIn: return "PowerTelemetryData.SystemPowerIn ÷ 1000"
        case .batteryPower: return "PowerTelemetryData.BatteryPower ÷ 1000"
        case .instantCurrent: return "InstantAmperage × Voltage ÷ 1000000"
        case .averageCurrent: return "Amperage × Voltage ÷ 1000000"
        case .adapterCurrent: return "SystemCurrentIn × SystemVoltageIn ÷ 1000000"
        default: return label
        }
    }
}

struct PowerReadingSources: Equatable {
    var system: PowerReadingSource = .unavailable
    var battery: PowerReadingSource = .unavailable
    var adapter: PowerReadingSource = .unavailable
}

/// Normalizes AppleSmartBattery readings once at the IOKit boundary.
/// Native current/BatteryPower: positive = charging, negative = discharging.
/// PowerData uses the opposite convention: positive = battery output to the Mac.
struct PowerMetrics: Equatable {
    let systemPowerW: Double
    let batteryPowerW: Double
    let acInputW: Double
    let sources: PowerReadingSources

    static func resolve(isOnAC: Bool, isCharging: Bool, voltageMV: Int?,
                        amperageMA: Int?, instantAmperageMA: Int?,
                        telemetry: [String: Any]?) -> PowerMetrics {
        func batteryOutput(currentMA: Int?) -> Double? {
            guard let currentMA, let voltageMV, voltageMV > 0 else { return nil }
            return -Double(currentMA) * Double(voltageMV) / 1_000_000
        }
        func watts(_ key: String) -> Double? {
            telemetry.flatMap { extractInt(from: $0, key: key) }.map { Double($0) / 1000 }
        }

        var sources = PowerReadingSources()
        var battery: Double?
        var rejectedBattery = false
        // Prefer reported watts, then this component's own I × V. Zero is valid.
        let batteryCandidates: [(Double?, PowerReadingSource)] = [
            (watts("BatteryPower").map { -$0 }, .batteryPower),
            (batteryOutput(currentMA: instantAmperageMA), .instantCurrent),
            (batteryOutput(currentMA: amperageMA), .averageCurrent)
        ]
        for (candidate, source) in batteryCandidates {
            guard let value = candidate else { continue }
            if (!isOnAC && value < -0.3) || (isOnAC && isCharging && value > 0.3) {
                rejectedBattery = true
                continue
            }
            battery = value
            sources.battery = source
            break
        }
        if battery == nil && rejectedBattery { sources.battery = .transition }

        var input: Double?
        if !isOnAC {
            input = 0 // Known from connection state, not a stale adapter sensor.
            sources.adapter = .disconnected
        } else if let reported = watts("SystemPowerIn"), reported >= 0 {
            input = reported
            sources.adapter = .systemPowerIn
        } else if let telemetry,
                  let voltage = extractInt(from: telemetry, key: "SystemVoltageIn"), voltage > 0,
                  let current = extractInt(from: telemetry, key: "SystemCurrentIn"), current >= 0 {
            // These are ADAPTER-input voltage/current, not a system-load sensor.
            input = Double(voltage) * Double(current) / 1_000_000
            sources.adapter = .adapterCurrent
        }

        var system: Double?
        if let reported = watts("SystemLoad"), reported >= 0 {
            system = reported
            sources.system = .systemLoad
        }

        // Derive at most the missing component from two independently known
        // values. Freeze these inputs so a derived value is never fed back into
        // another estimate; two missing readings must stay unavailable.
        let knownSystem = system, knownBattery = battery, knownInput = input
        if system == nil, let input = knownInput, let battery = knownBattery,
           input + battery >= 0 {
            system = input + battery
            sources.system = isOnAC ? .powerBalance : .batteryEstimate
        }
        if battery == nil, !rejectedBattery, let system = knownSystem, let input = knownInput {
            let estimated = system - input
            if isOnAC && isCharging && estimated > 0.3 {
                sources.battery = .transition
            } else {
                battery = estimated
                sources.battery = .powerBalance
            }
        }
        if input == nil, isOnAC, let system = knownSystem, let battery = knownBattery,
           system - battery >= 0 {
            input = system - battery
            sources.adapter = .powerBalance
        }
        return PowerMetrics(systemPowerW: system ?? 0, batteryPowerW: battery ?? 0,
                            acInputW: input ?? 0, sources: sources)
    }
}
