import Foundation

enum MenuBarItemKind: String, CaseIterable, Identifiable, Codable {
    case battery, power, cpu, gpu, memory, network, temperature, fans, disk
    var id: String { rawValue }
    static let defaultOrder = allCases
    var title: String {
        switch self {
        case .battery: return String(localized: "Battery Level")
        case .power: return String(localized: "Menu Bar Power")
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return String(localized: "Memory Usage")
        case .network: return String(localized: "Network Speed")
        case .temperature: return String(localized: "CPU Temperature")
        case .fans: return String(localized: "Fans")
        case .disk: return String(localized: "Startup Disk")
        }
    }
    static func normalized(_ values: [String]?) -> [Self] {
        var result: [Self] = []
        for value in values ?? [] {
            if let item = Self(rawValue: value), !result.contains(item) { result.append(item) }
        }
        return result + allCases.filter { !result.contains($0) }
    }
}
