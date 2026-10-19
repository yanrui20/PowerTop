import Foundation
import IOKit
import Darwin

/// Decodes only read-only numeric SMC values used by the sensors below.
enum SMCNumberDecoder {
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            value = bytes.withUnsafeBytes { Double($0.loadUnaligned(as: Float.self)) }
        case "sp78":
            guard bytes.count == 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ":
            guard bytes.count == 1 else { return nil }
            value = Double(bytes[0])
        case "ui16", "ui32":
            guard bytes.count == (type == "ui16" ? 2 : 4) else { return nil }
            value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}

/// Actor-confined, read-only AppleSMC connection. No write operation, fan-mode
/// change, target-speed key, or arbitrary command is exposed.
final class HardwareSensorsReader {
    private var connection: io_connect_t = 0
    private var metadata: [String: (size: UInt32, type: String)] = [:]
    private var missingKeys = Set<String>()
    private let cpuKeys: [String]
    init() { cpuKeys = Self.cpuTemperatureKeys(model: Self.cpuModel()) }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read(temperature: Bool = true, fans readFans: Bool = true) -> HardwareReadings {
        guard temperature || readFans else { return .init() }
        guard open() else { return .init() }
        let temperatures = (temperature ? cpuKeys : []).compactMap { key -> Double? in
            guard let value = value(for: key), value > 0, value < 150 else { return nil }
            return value
        }
        let cpu = temperatures.isEmpty ? nil : CPUTemperature(
            averageCelsius: temperatures.reduce(0, +) / Double(temperatures.count),
            maximumCelsius: temperatures.max()!, sensorCount: temperatures.count)
        var fans: [FanSpeed]?
        if readFans, let number = value(for: "FNum"), number >= 0, number <= 16, number.rounded() == number {
            fans = (0..<Int(number)).map { index in
                let speed = value(for: String(format: "F%XAc", index))
                let valid = speed.flatMap { (0...30_000).contains($0) ? $0 : nil }
                return FanSpeed(index: index, rpm: valid)
            }
        }
        return HardwareReadings(cpuTemperature: cpu, fans: fans)
    }

    private func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    private func value(for key: String) -> Double? {
        guard key.utf8.count == 4, !missingKeys.contains(key), open() else { return nil }
        let info: (size: UInt32, type: String)
        if let cached = metadata[key] {
            info = cached
        } else {
            guard let response = request(key: key, operation: 9) else { return nil }
            let size = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
            let code = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
            guard size > 0, size <= 32,
                  let type = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }, encoding: .ascii) else { return nil }
            info = (size, type)
            metadata[key] = info
        }
        guard let response = request(key: key, operation: 5, size: info.size) else { return nil }
        return SMCNumberDecoder.decode(type: info.type, bytes: Array(response[48..<48 + Int(info.size)]))
    }

    // AppleSMC's 80-byte ABI: key at 0, keyInfo at 28, result at 40,
    // read command at 42, and 32-byte payload at 48. Explicit buffers avoid
    // Swift nested-struct tail-padding differences from the C ABI.
    private func request(key: String, operation: UInt8, size: UInt32 = 0) -> [UInt8]? {
        guard operation == 5 || operation == 9 else { return nil }
        var input = [UInt8](repeating: 0, count: 80), output = input
        input.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
        }
        input[42] = operation
        var outputSize = 80
        let status = input.withUnsafeBytes { i in output.withUnsafeMutableBytes { o in
            IOConnectCallStructMethod(connection, 2, i.baseAddress, 80, o.baseAddress, &outputSize)
        }}
        guard status == KERN_SUCCESS else {
            IOServiceClose(connection)
            connection = 0
            metadata.removeAll()
            missingKeys.removeAll()
            return nil
        }
        guard outputSize >= 80 else { return nil }
        if output[40] == 0x84 { missingKeys.insert(key) }
        guard output[40] == 0 else { return nil }
        return output
    }

    private static func cpuModel() -> String {
        var length = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0) == 0, length > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &length, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    // CPU-only keys are selected by chip generation: a key can describe a
    // different sensor on another model. Unknown chips report unavailable.
    // Mapping reference: github.com/exelban/stats, Modules/Sensors/values.swift.
    static func cpuTemperatureKeys(model: String) -> [String] {
        let generation = model.split(separator: " ").prefix(2).joined(separator: " ")
        if generation == "Apple M5" {
            return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        }
        if generation == "Apple M4" {
            return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        }
        if generation == "Apple M3" {
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        }
        if generation == "Apple M2" {
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        }
        if generation == "Apple M1" {
            return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        }
        if model.contains("Intel") { return ["TCAD"] }
        return []
    }
}
