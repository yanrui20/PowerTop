import Foundation
import AppKit

actor StartupFixture: StartupItemsBackend {
    private var values: [StartupItem] = [
        .init(id: "a", name: "First", applicationName: "Example", applicationURL: nil, sourceURL: URL(fileURLWithPath: "/tmp/first.plist"), executableURL: nil, kind: .userAgent, management: .launchd, enabled: true, label: "example.first", loaded: true),
        .init(id: "b", name: "Second", applicationName: "Example", applicationURL: nil, sourceURL: URL(fileURLWithPath: "/tmp/second.plist"), executableURL: nil, kind: .userAgent, management: .launchd, enabled: true, label: "example.second", loaded: true)
    ]
    private var fail = false
    private var refuseLoad = false
    private var refuseUnload = false
    func refuseUnloading(_ refuse: Bool) { refuseUnload = refuse }
    func unloadFirst() { values[0].enabled = true; values[0].loaded = false }
    func refuseLoading(_ refuse: Bool) { refuseLoad = refuse }
    private var reads = 0
    func readCount() -> Int { reads }
    func failNext(_ value: Bool) { fail = value }
    func read() async throws -> StartupSnapshot { reads += 1; return .init(items: values) }
    func setEnabled(_ enabled: Bool, item: StartupItem) async throws {
        if fail { throw StartupError.unavailable("Test failure") }
        let index = values.firstIndex { $0.id == item.id }!
        values[index].enabled = enabled
        if enabled && !refuseLoad { values[index].loaded = true }
        if !enabled && !refuseUnload { values[index].loaded = false }
    }
}

@main struct StartupLayoutTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let text = """
        Records for UID 501 : test
         #1:
          Name: Example
          Type: app (0x2)
          Identifier: 2.example
          URL: file:///Applications/Example%20App.app/
         #2:
          Name: Helper
          Type: agent (0x8)
          Identifier: 8.example.helper
          URL: Contents/Library/LaunchAgents/example.plist
          Parent Identifier: 2.example
          Disposition: [enabled, allowed, notified] (0xb)
         #3:
          Name: Blocked
          Type: legacy agent (0x10008)
          Identifier: 8.blocked
          URL: file:///Library/LaunchAgents/blocked.plist
          Disposition: [enabled, disallowed, notified] (0x9)
        Records for UID 502 : other
         #1:
          Identifier: 2.otheruser
          Type: app (0x2)
        """
        let records = BackgroundTaskRecord.parse(text, uid: 501)
        precondition(records.count == 3 && records[1].enabled == true && records[2].enabled == false)
        precondition(records[1].fileURL(key: "URL", records: records)?.path == "/Applications/Example App.app/Contents/Library/LaunchAgents/example.plist")
        let overrides = StartupValidation.disabledOverrides("\"a\" => enabled\n\"b\" => disabled\n\"c\" => true\n\"d\" => false")
        precondition(overrides == ["a": false, "b": true, "c": true, "d": false])
        for bad in ["com.apple.security", "../bad", "x; touch file", "a\nb", "a\n", "$(id)", ""] { precondition(!StartupValidation.validLabel(bad)) }
        precondition(StartupValidation.validLabel("com.example.helper-1"))
        let owner = StartupOwner(url: URL(fileURLWithPath: "/Applications/Example.app"), bundleID: "com.example", teamID: "TEAM")
        precondition(StartupValidation.ownerURL(label: "com.example.helper", teamID: "TEAM", candidates: [owner]) == owner.url)
        precondition(StartupValidation.ownerURL(label: "com.other.helper", teamID: "TEAM", candidates: [owner]) == nil)
        precondition(StartupValidation.ownerURL(label: "com.example.helper", teamID: "OTHER", candidates: [owner]) == nil)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let agents = temp.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = agents.appendingPathComponent("example.plist")
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        precondition(SystemStartupItemsBackend.allowedSource(file, system: false, home: temp, uid: Int(getuid())))
        precondition(!SystemStartupItemsBackend.allowedSource(file, system: true, home: temp, uid: Int(getuid())))
        let link = agents.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(!SystemStartupItemsBackend.allowedSource(link, system: false, home: temp, uid: Int(getuid())))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        precondition(!SystemStartupItemsBackend.allowedSource(file, system: false, home: temp, uid: Int(getuid())))
        let backend = StartupFixture()
        let startup = StartupItemsController(backend: backend)
        let initialReads = await backend.readCount()
        precondition(initialReads == 0, "Constructing the manager must not read startup items")
        await startup.refresh()
        precondition(startup.groups.count == 1 && startup.groups[0].items.count == 2)
        precondition(startup.groups[0].state == .enabled)
        await startup.setEnabled(false, item: startup.items[0])
        precondition(startup.items[0].enabled == false && startup.items[1].enabled == true)
        precondition(startup.groups[0].state == .partial)
        let afterChildReads = await backend.readCount()
        precondition(afterChildReads == 2, "Only one final verification read per change")
        await backend.failNext(true)
        await startup.setEnabled(false, item: startup.items[1])
        precondition(startup.items[1].enabled == true && startup.error != nil)
        startup.query = "second.plist"
        precondition(Set(startup.groups[0].items.map(\.id)) == ["a", "b"], "Search must not narrow a group's master switch")
        await backend.failNext(false)
        await startup.setEnabled(false, group: startup.groups[0])
        precondition(startup.items.allSatisfy { $0.enabled == false } && startup.groups[0].state == .disabled)
        await startup.setEnabled(true, group: startup.groups[0])
        precondition(startup.items.allSatisfy { $0.enabled == true } && startup.groups[0].state == .enabled)
        await backend.unloadFirst()
        await startup.refresh()
        precondition(startup.items[0].state == .unloaded && !startup.items[0].switchIsOn)
        precondition(startup.groups[0].state == .partial)
        await backend.refuseLoading(true)
        await startup.setEnabled(true, item: startup.items[0])
        precondition(startup.error != nil && startup.items[0].state == .unloaded, "Enabling must not claim success without registration")
        await backend.refuseLoading(false)
        await startup.setEnabled(true, item: startup.items[0])
        precondition(startup.error == nil && startup.items[0].switchIsOn)
        await backend.refuseUnloading(true)
        await startup.setEnabled(false, item: startup.items[0])
        precondition(startup.error != nil && startup.items[0].loaded == true)
        precondition(startup.items[0].switchIsOn, "Like Lemon, a loaded service stays on even when auto-start is disabled")
        var unknownPermission = startup.items[0]
        unknownPermission.enabled = nil
        precondition(unknownPermission.switchIsOn, "Loaded status determines on independently of auto-start permission")
        precondition(startup.items[0].needsChange(to: false), "A failed unload must remain retryable even after disable succeeded")
        await backend.refuseUnloading(false)
        await startup.setEnabled(false, item: startup.items[0])
        precondition(startup.error == nil && startup.items[0].loaded == false && startup.items[0].enabled == false)
        let quietReads = await backend.readCount()

        let suite = "PowerTop.ArrangementTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["network", "cpu", "cpu", "invalid"], forKey: "menuBarItemOrder")
        let monitor = PowerMonitor(defaults: defaults)
        precondition(Array(monitor.menuBarOrder.prefix(2)) == [.network, .cpu])
        precondition(Set(monitor.menuBarOrder).count == MenuBarItemKind.allCases.count)
        monitor.moveMenuBarItem(.cpu, offset: -1)
        precondition(monitor.menuBarOrder.first == .cpu)
        monitor.moveMenuBarItems(from: IndexSet(integer: 0), to: monitor.menuBarOrder.count)
        precondition(monitor.menuBarOrder.last == .cpu)
        precondition(PowerMonitor(defaults: defaults).menuBarOrder == monitor.menuBarOrder)
        monitor.setMenuBarItem(.network, enabled: false)
        precondition(!monitor.isMenuBarItemEnabled(.network))
        let resources: [MenuBarResourceItem] = [.percent(23, label: "CPU"), .percent(40, label: "GPU")]
        func presentation(_ mode: EnergyMode) -> MenuBarPresentation {
            .init(available: true, percent: 75, charging: true, onAC: true, showBattery: true, showPower: true,
                  powerText: "25W", mode: mode, resources: resources)
        }
        let normal = NSBitmapImageRep(data: presentation(.automatic).compactStatusImage(normalColor: .white)!.tiffRepresentation!)!
        let low = NSBitmapImageRep(data: presentation(.low).compactStatusImage(normalColor: .white)!.tiffRepresentation!)!
        precondition(normal.pixelsWide == low.pixelsWide)
        let energyWidth = presentation(.automatic).batteryColumn!.width + presentation(.automatic).powerColumn!.width + 2
        let batteryEnd = Int(Double(normal.pixelsWide) * Double(energyWidth) / Double(normal.size.width))
        var changedBattery = false
        for y in 0..<normal.pixelsHigh {
            for x in 0..<normal.pixelsWide {
                let equal = normal.colorAt(x: x, y: y) == low.colorAt(x: x, y: y)
                if x >= batteryEnd { precondition(equal, "Only battery and power pixels may turn yellow") }
                else if !equal { changedBattery = true }
            }
        }
        precondition(changedBattery)
        let reordered = MenuBarPresentation(available: true, percent: 75, charging: false, onAC: true,
            showBattery: true, showPower: true, powerText: "25W", resources: resources,
            itemOrder: [.gpu, .power, .cpu, .battery])
        precondition(reordered.visibleItemOrder == [.gpu, .power, .cpu, .battery])
        let controller = StatusItemController(monitor: monitor)
        try await Task.sleep(for: .milliseconds(250))
        for iteration in 0..<5 {
            controller.clickForTest()
            try await Task.sleep(for: .milliseconds(100))
            precondition(controller.testPopoverVisible && controller.testDismissMonitorsActive, "Open failed at iteration \(iteration): shown=\(controller.testPopoverVisible), monitors=\(controller.testDismissMonitorsActive)")
            controller.clickForTest()
            monitor.showCPUInMenuBar.toggle() // Queued layout changes must not reopen it.
            try await Task.sleep(for: .milliseconds(150))
            precondition(!controller.testPopoverVisible && !controller.testDismissMonitorsActive)
            controller.clickForTest()
            try await Task.sleep(for: .milliseconds(100))
            controller.outsideClickForTest()
            try await Task.sleep(for: .milliseconds(150))
            precondition(!controller.testPopoverVisible && !controller.testDismissMonitorsActive)
        }
        controller.clickForTest()
        try await Task.sleep(for: .milliseconds(100))
        controller.externalClickForTest()
        try await Task.sleep(for: .milliseconds(100))
        precondition(!controller.testPopoverVisible, "Other-app clicks must close even at overlapping coordinates")
        controller.clickForTest(); controller.clickForTest()
        try await Task.sleep(for: .milliseconds(100))
        precondition(!controller.testPopoverVisible, "Closing must cancel a queued opening")
        controller.invalidate()
        let finalReads = await backend.readCount()
        precondition(finalReads == quietReads, "Menu bar changes and popover activity must not refresh startup items")
        print("PASS: per-child startup changes, BTM paths/status, source validation, order persistence, battery-only tint, repeated toggle/outside dismissal and queued-open cancellation")
        if CommandLine.arguments.contains("--read-system") {
            let snapshot = try await SystemStartupItemsBackend().read()
            precondition(Set(snapshot.items.map(\.id)).count == snapshot.items.count)
            print("LIVE startup items=\(snapshot.items.count), direct controls=\(snapshot.items.filter { $0.management.canToggle }.count), source files=\(snapshot.items.filter { $0.sourceURL != nil }.count), warnings=\(snapshot.warnings.count)")
            print("LIVE warnings:", snapshot.warnings)
            for item in snapshot.items where item.label?.hasPrefix("com.vivo.") == true {
                print("LIVE vivo", item.sourceTitle, "allowed=", item.enabled as Any, "loaded=", item.loaded as Any, "state=", item.state)
            }
        }
    }
}
