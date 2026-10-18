import Foundation
import IOKit

/// A fixed, non-exclusive request to READ all battery registers. No mode,
/// charging-control, polling-period or arbitrary selector is exposed to clients.
enum SystemBatterySampling {
    static func request() -> Int32 {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryManager"))
        guard service != 0 else { return kIOReturnNotFound }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == KERN_SUCCESS else { return opened }
        defer { IOServiceClose(connection) }
        var type: UInt64 = 2 // kIOPSReadAll
        return IOConnectCallScalarMethod(connection, 4, &type, 1, nil, nil) // kSBRequestPoll
    }

    static func requestWasAccepted(_ status: Int32) -> Bool {
        // Apple's AppleSmartBatteryManager::requestPoll returns bool (1 = started),
        // although externalMethod is typed IOReturn. Accept standard success too;
        // the application separately verifies a NEW UpdateTime before claiming success.
        status == KERN_SUCCESS || status == 1
    }

    static func updateTimestamp() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "UpdateTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return nil }
        let stamp = value.doubleValue
        return stamp.isFinite && stamp > 0 ? stamp : nil
    }
}
