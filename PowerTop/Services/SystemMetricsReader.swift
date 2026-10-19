import Foundation
import Darwin
import IOKit

protocol SystemMetricsReading: Sendable {
    func read(selection: SystemMetricSelection, forceSlow: Bool) async -> RawSystemMetrics
}
extension SystemMetricsReading {
    func read() async -> RawSystemMetrics { await read(selection: .all, forceSlow: false) }
}

/// Reads existing counters and driver statistics without privileged sampling.
actor SystemMetricsReader: SystemMetricsReading {
    private let sensors = HardwareSensorsReader()
    private var diskCache = SlowMetricCache<DiskUsage>()
    private var previousSelection: SystemMetricSelection = []
    static let diskInterval: TimeInterval = 60
    func read(selection: SystemMetricSelection, forceSlow: Bool) async -> RawSystemMetrics {
        let now = ProcessInfo.processInfo.systemUptime
        let disk = selection.contains(.disk) ? diskCache.value(at: now, interval: Self.diskInterval,
            force: forceSlow || !previousSelection.contains(.disk), load: Self.readDisk) : nil
        previousSelection = selection
        return RawSystemMetrics(uptime: now,
            cpu: selection.contains(.cpu) ? readCPU() : nil,
            gpuPercent: selection.contains(.gpu) ? readGPU() : nil,
            memory: selection.contains(.memory) ? readMemory() : nil,
            network: selection.contains(.network) ? readNetwork() : nil,
            hardware: sensors.read(temperature: selection.contains(.temperature), fans: selection.contains(.fans)), disk: disk)
    }

    private static func readDisk() -> DiskUsage? {
        // The writable startup volume avoids counting the sealed system snapshot
        // as a separate disk. APFS siblings share their container's free space.
        let path = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return DiskUsage.resolve(total: values.volumeTotalCapacity.map(Int64.init),
            available: values.volumeAvailableCapacity.map(Int64.init),
            importantAvailable: values.volumeAvailableCapacityForImportantUsage)
    }

    private func readCPU() -> CPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                        idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func readMemory() -> MemoryUsage? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return MemoryUsage.fromPages(active: info.active_count, inactive: info.inactive_count,
            speculative: info.speculative_count, wired: info.wire_count,
            compressed: info.compressor_page_count, purgeable: info.purgeable_count,
            fileBacked: info.external_page_count, pageSize: UInt64(pageSize),
            total: ProcessInfo.processInfo.physicalMemory)
    }

    private func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue,
                value.isFinite, (0...100).contains(value) else { continue }
            values.append(value)
        }
        // Without capacity weights, averaging different GPUs would be misleading.
        return values.max()
    }

    private func readNetwork() -> NetworkCounters? {
        // Read all 64-bit interface counters; aggregate with the same interface-type
        // selection and fallback rules as Lemon's public network sampler.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &length, nil, 0) }
        guard status == 0 else { return nil }
        return bytes.withUnsafeBytes { raw in
            var offset = 0
            var interfaces: [NetworkInterfaceCounters] = []
            while offset + 4 <= length {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength >= 4, offset + messageLength <= length else { return nil }
                let type = raw.load(fromByteOffset: offset + 3, as: UInt8.self)
                if type == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    interfaces.append(.init(type: info.ifm_data.ifi_type,
                        received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes))
                }
                offset += messageLength
            }
            guard offset == length else { return nil }
            return NetworkCounters.aggregate(interfaces)
        }
    }
}
