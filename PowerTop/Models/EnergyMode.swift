import Foundation

enum EnergyMode: Int, CaseIterable, Sendable {
    case automatic = 0, low = 1, high = 2

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .low: String(localized: "Low Power")
        case .high: String(localized: "High Power")
        }
    }
}

enum EnergyPowerSource: String, CaseIterable, Sendable {
    case battery = "Battery Power", adapter = "AC Power"
    var argument: String { self == .battery ? "-b" : "-c" }
    var title: String {
        self == .battery ? String(localized: "On Battery") : String(localized: "On Power Adapter")
    }
}

struct EnergyModeSetting: Equatable, Sendable {
    let mode: EnergyMode
    let supportsHighPower: Bool

    // pmset reports a tri-state powermode on supported Macs and lowpowermode elsewhere.
    // Unknown/missing values must not be presented as Automatic.
    static func parse(_ output: String) -> [EnergyPowerSource: EnergyModeSetting] {
        var result: [EnergyPowerSource: EnergyModeSetting] = [:]
        var source: EnergyPowerSource?
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") {
                source = EnergyPowerSource(rawValue: String(text.dropLast()))
                continue
            }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard let source, fields.count == 2,
                  fields[0] == "powermode" || fields[0] == "lowpowermode",
                  let value = Int(fields[1]), let mode = EnergyMode(rawValue: value) else { continue }
            // A lowpowermode value of 2 alone does not prove capability (e.g. a restricted process).
            result[source] = EnergyModeSetting(mode: mode, supportsHighPower: fields[0] == "powermode")
        }
        return result
    }

    func command(for mode: EnergyMode, source: EnergyPowerSource) throws -> String {
        guard mode != .high || supportsHighPower else { throw EnergyModeError.unsupported }
        let key = supportsHighPower ? "powermode" : "lowpowermode"
        // All command components are fixed enum values; no user text enters the shell.
        return "/usr/bin/pmset \(source.argument) \(key) \(mode.rawValue)"
    }
}

enum EnergyModeError: LocalizedError {
    case unavailable, unsupported, verificationFailed, cancelled, commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Unable to read energy modes.")
        case .unsupported: String(localized: "High Power Mode is not available for this power source.")
        case .verificationFailed: String(localized: "macOS did not confirm the requested energy mode.")
        case .cancelled: String(localized: "Energy mode change cancelled.")
        case .commandFailed(let message): message
        }
    }
}
