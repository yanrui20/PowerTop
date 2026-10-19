import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PowerMonitor()
    private var didStart = false
    private var statusItemController: StatusItemController?

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        if CommandLine.arguments.contains("--verify-startup-service") || CommandLine.arguments.contains("--inspect-startup-items") {
            Task {
                do {
                    try await PrivilegedEnergyHelper.shared.ping()
                    let backend = SystemStartupItemsBackend()
                    if CommandLine.arguments.contains("--inspect-startup-items") {
                        let snapshot = try await backend.read()
                        for item in snapshot.items {
                            print("\(item.applicationName) | \(item.sourceTitle) | \(item.state) | allowed=\(String(describing: item.enabled)) loaded=\(String(describing: item.loaded))")
                        }
                        for warning in snapshot.warnings { fputs("Startup warning: \(warning)\n", stderr) }
                        exit(snapshot.warnings.isEmpty ? 0 : 1)
                    }
                    for pass in 1...2 {
                        let snapshot = try await backend.read()
                        guard snapshot.warnings.isEmpty else { throw StartupError.unavailable(snapshot.warnings.joined(separator: "\n")) }
                        print("PASS startup read \(pass): \(snapshot.items.count) items, no authorization dialog requested")
                    }
                    do {
                        try await PrivilegedEnergyHelper.shared.setStartupDaemonEnabled(false, sourcePath: "/tmp/invalid.plist", label: "com.apple.security")
                        fputs("FAIL: unsafe startup request accepted\n", stderr); exit(1)
                    } catch { print("PASS: unsafe startup request rejected; no startup settings changed") }
                    exit(0)
                } catch { fputs("Startup service: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--configure-admin-service") || CommandLine.arguments.contains("--verify-active-refresh") {
            Task { @MainActor in
                if CommandLine.arguments.contains("--configure-admin-service") {
                    await monitor.energyModes.configureAdministratorAuthorization(enabled: true)
                    if let error = monitor.energyModes.authorizationError {
                        fputs("Administrator service: \(error)\n", stderr); exit(1)
                    }
                }
                do {
                    try await PrivilegedEnergyHelper.shared.ping()
                    let before = SystemBatterySampling.updateTimestamp()
                    let after = try await monitor.refreshImmediately()
                    print("PASS: shared administrator service; sample timestamp \(String(describing: before)) -> \(after); system=\(monitor.currentData.systemPowerW)W")
                    exit(0)
                } catch { fputs("Active refresh: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            return
        }
        monitor.start()
        statusItemController = StatusItemController(monitor: monitor)
        if CommandLine.arguments.contains("--smoke-launch") {
            scheduleSmokeLaunchCheck()
        }
    }

    /// Automated launch check: fail if a content window appeared (the old flash).
    private func scheduleSmokeLaunchCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard self != nil else { exit(1) }
            let visible = NSApp.windows.filter(\.isVisible)
            let leaked = visible.filter { window in
                let title = window.title
                if title.contains("Details") { return true }
                // Status item's button window is tiny; a leaked panel is not.
                return window.frame.width >= 200 && window.frame.height >= 80
            }
            if let widths = self?.statusItemController?.menuBarLayoutWidths {
                guard widths.occupied <= widths.button + 1 else {
                    fputs("smoke-launch FAIL: extra status item spacing: \(widths)\n", stderr)
                    exit(1)
                }
                fputs("smoke-launch compact menu bar: \(widths)\n", stderr)
            }
            if leaked.isEmpty {
                fputs("smoke-launch OK: no content window at launch\n", stderr)
                exit(0)
            } else {
                let desc = leaked.map { "\($0.title) \($0.frame.size)" }.joined(separator: "; ")
                fputs("smoke-launch FAIL: visible windows: \(desc)\n", stderr)
                exit(1)
            }
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            startIfNeeded()
        }
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            monitor.refreshNow()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            statusItemController?.invalidate()
            statusItemController = nil
            monitor.stop()
        }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PowerTopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Run before SwiftUI evaluates even the uninserted MenuBarExtra.
        StatusItemController.configureMenuBarSpacing()
    }

    var body: some Scene {
        // SwiftUI requires a Scene. Window/Settings present at launch (the flash).
        // A MenuBarExtra with isInserted=false is not shown; the real extra is AppKit.
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            EmptyView()
        }
    }
}
