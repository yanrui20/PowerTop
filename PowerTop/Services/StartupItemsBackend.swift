import Foundation
import ServiceManagement
import Darwin

protocol StartupItemsBackend: Sendable {
    func read() async throws -> StartupSnapshot
    func setEnabled(_ enabled: Bool, item: StartupItem) async throws
    func setEnabled(_ enabled: Bool, items: [StartupItem]) async throws
}

extension StartupItemsBackend {
    func setEnabled(_ enabled: Bool, items: [StartupItem]) async throws {
        for item in items { try await setEnabled(enabled, item: item) }
    }
}

actor SystemStartupItemsBackend: StartupItemsBackend {
    private let uid = Int(getuid())
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    func read() async throws -> StartupSnapshot {
        var items: [StartupItem] = [], warnings: [String] = []
        let userState = try run("/bin/launchctl", ["print-disabled", "gui/\(uid)"])
        let userDisabled = StartupValidation.disabledOverrides(userState)
        let userLoaded = (try? run("/bin/launchctl", ["list"])).flatMap(StartupServicePolicy.loadedLabels)
        if userLoaded == nil { warnings.append(String(localized: "User service loading states could not be read.")) }
        // dumpbtm can display an authorization dialog even for read-only queries.
        // Always use the already-authorized helper; never silently fall back to it locally.
        var systemState = try? run("/bin/launchctl", ["print-disabled", "system"])
        var btmText: String?
        var systemLoaded: Set<String>?
        do {
            let state = try await PrivilegedEnergyHelper.shared.readStartupState()
            systemState = state.system; btmText = state.background
            systemLoaded = StartupServicePolicy.loadedLabels(state.loaded)
        } catch {
            warnings.append(String(localized: "Authorize or repair the shared administrator service to read all background items without password prompts."))
        }
        let systemDisabled = systemState.map(StartupValidation.disabledOverrides)
        if systemLoaded == nil { warnings.append(String(localized: "System service loading states could not be read.")) }
        if systemState == nil { warnings.append(String(localized: "System service states could not be read.")) }
        let records = btmText.map { BackgroundTaskRecord.parse($0, uid: uid) } ?? []
        if records.isEmpty { warnings.append(String(localized: "Additional macOS background items are currently unavailable.")) }
        let owners: [StartupOwner] = records.compactMap { record in
            guard let team = record.fields["Team Identifier"],
                  let app = StartupValidation.appURL(containing: record.fileURL(key: "Executable Path", records: records)
                      ?? record.fileURL(key: "URL", records: records)),
                  app.path.hasPrefix("/Applications/") || app.path.hasPrefix(home.appendingPathComponent("Applications").path + "/"),
                  let identifier = Bundle(url: app)?.bundleIdentifier else { return nil }
            return .init(url: app, bundleID: identifier, teamID: team)
        }
        var sources: [(URL, StartupKind)] = []
        for (folder, kind) in [(home.appendingPathComponent("Library/LaunchAgents"), StartupKind.userAgent),
                               (URL(fileURLWithPath: "/Library/LaunchAgents"), .sharedAgent),
                               (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon)] {
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                sources += urls.filter { $0.pathExtension == "plist" }.map { ($0, kind) }
            } catch { warnings.append("\(folder.path): \(error.localizedDescription)") }
        }
        // Modern bundled agents have relative URLs; resolve them against their
        // owning app's BTM record instead of guessing a filesystem location.
        for record in records where record.type.contains("agent") || record.type.contains("daemon") {
            guard let url = record.fileURL(key: "URL", records: records), url.pathExtension == "plist",
                  !url.path.hasPrefix("/System/"), !sources.contains(where: { $0.0.path == url.path }) else { continue }
            let kind: StartupKind = record.type.contains("daemon") ? .daemon : .bundledService
            sources.append((url, kind))
        }
        for (url, kind) in sources {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String, !label.hasPrefix("com.apple.") else { continue }
            let record = records.first { $0.fileURL(key: "URL", records: records)?.path == url.path }
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            let executable = program.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? record?.fileURL(key: "Executable Path", records: records)
            var appURL = StartupValidation.appURL(containing: executable) ?? StartupValidation.appURL(containing: url)
            if appURL == nil, let ids = plist["AssociatedBundleIdentifiers"] as? [String] {
                appURL = records.first { ids.contains(String($0.identifier.dropFirst(2))) && $0.type.hasPrefix("app ") }?.fileURL(key: "URL", records: records)
            }
            // Group out-of-bundle helpers only with an unambiguous installed
            // owner whose signing team AND bundle-id namespace both match.
            if let owner = StartupValidation.ownerURL(label: label, teamID: record?.fields["Team Identifier"], candidates: owners) {
                appURL = owner
            }
            let name = appURL?.deletingPathExtension().lastPathComponent ?? record?.name ?? label
            let system = kind == .daemon
            let overrides = system ? systemDisabled : userDisabled
            let disabled = overrides?[label] ?? (plist["Disabled"] as? Bool ?? false)
            var enabled: Bool? = overrides == nil ? nil : !disabled
            var management = StartupManagement.launchd
            var explanation: String?
            if !StartupValidation.validLabel(label) {
                management = .readOnly
                explanation = String(localized: "This service identifier cannot be changed directly.")
            }
            if kind == .bundledService {
                management = .systemSettings
                enabled = record?.enabled
                explanation = String(localized: "This bundled service is registered by its owning app. Manage it in System Settings.")
            }
            if record?.permissionBlocked == true || record?.fields["Flags"]?.contains("managed") == true {
                if record?.permissionBlocked == true { enabled = false }
                management = .systemSettings
                explanation = String(localized: "macOS controls this item's background permission.")
            }
            if label == EnergyHelperConstants.service {
                management = .readOnly
                explanation = String(localized: "Manage PowerTop's battery helper under Administrator Authorization.")
            }
            if !Self.allowedSource(url, system: system, home: home, uid: uid) {
                management = .systemSettings
                explanation = String(localized: "Manage this item in System Settings or its owning application.")
            }
            items.append(.init(id: "launchd:\(system ? "system" : "gui"):\(label):\(url.path)",
                name: record?.name ?? label, applicationName: name, applicationURL: appURL,
                sourceURL: url, executableURL: executable, kind: kind, management: management,
                enabled: enabled, explanation: explanation, label: label, systemDomain: system,
                loaded: (system ? systemLoaded : userLoaded).map { $0.contains(label) },
                canLoadInCurrentSession: system || StartupServicePolicy.supportsCurrentSession(plist)))
        }
        // A launchd override addresses a label, not a file. Do not offer a
        // misleading per-file toggle when two files declare the same label.
        let counts = Dictionary(grouping: items, by: { "\($0.systemDomain):\($0.label ?? "")" })
        for i in items.indices where (counts["\(items[i].systemDomain):\(items[i].label ?? "")"]?.count ?? 0) > 1 {
            items[i].management = .readOnly
            items[i].explanation = String(localized: "Multiple files use this service label. Inspect the original files before changing it.")
        }

        let ownApp = Bundle.main.bundleURL.standardizedFileURL
        let hasOwnApp = ownApp.pathExtension == "app"
        do {
            for login in try await LegacyLoginItems.records() where !hasOwnApp || login.url.path != ownApp.path {
                let exists = FileManager.default.fileExists(atPath: login.url.path)
                items.append(.init(id: "login:\(login.url.path)", name: login.name,
                    applicationName: login.name, applicationURL: login.url, sourceURL: login.url,
                    executableURL: nil, kind: .loginApp, management: exists ? .legacyLogin : .readOnly,
                    enabled: login.enabled, explanation: exists ? nil : String(localized: "The original file is missing.")))
            }
        } catch { warnings.append(error.localizedDescription) }
        if hasOwnApp {
            let status = SMAppService.mainApp.status
            items.append(.init(id: "own-login", name: ownApp.deletingPathExtension().lastPathComponent,
                applicationName: ownApp.deletingPathExtension().lastPathComponent, applicationURL: ownApp,
                sourceURL: ownApp, executableURL: nil, kind: .loginApp, management: .ownApp,
                enabled: status == .enabled, explanation: status == .requiresApproval ? StartupError.approvalRequired.localizedDescription : nil))
        }
        for record in records where record.type.lowercased().contains("login") {
            guard let url = record.fileURL(key: "URL", records: records),
                  !items.contains(where: { $0.sourceURL?.path == url.path }) else { continue }
            let appURL = StartupValidation.appURL(containing: url)
            items.append(.init(id: "btm:\(record.identifier)", name: record.name,
                applicationName: appURL?.deletingPathExtension().lastPathComponent ?? record.name,
                applicationURL: appURL, sourceURL: url, executableURL: nil, kind: .loginApp,
                management: .systemSettings, enabled: record.enabled,
                explanation: String(localized: "Manage this item in System Settings or its owning application.")))
        }
        return .init(items: items.sorted { $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending }, warnings: warnings)
    }

    func setEnabled(_ enabled: Bool, item: StartupItem) async throws {
        try await setEnabled(enabled, items: [item])
    }

    func setEnabled(_ enabled: Bool, items: [StartupItem]) async throws {
        // One preflight for the entire group; the controller performs one final readback.
        let snapshot = try await read()
        var currentItems: [StartupItem] = []
        for item in items {
            guard let current = snapshot.items.first(where: { $0.id == item.id }),
                  current.sourceURL == item.sourceURL, current.label == item.label,
                  current.management.canToggle else { throw StartupError.changed }
            currentItems.append(current)
        }
        var failures: [String] = []
        for current in currentItems where current.needsChange(to: enabled) {
            do { try await apply(enabled, item: current) }
            catch { failures.append(current.sourceTitle + ": " + error.localizedDescription) }
        }
        if !failures.isEmpty { throw StartupError.unavailable(failures.joined(separator: "\n")) }
    }

    private func apply(_ enabled: Bool, item current: StartupItem) async throws {
        switch current.management {
        case .ownApp:
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { throw StartupError.approvalRequired }
        case .legacyLogin:
            guard let url = current.sourceURL else { throw StartupError.changed }
            try await LegacyLoginItems.setEnabled(enabled, url: url)
        case .launchd:
            guard let label = current.label, StartupValidation.validLabel(label),
                  let url = current.sourceURL, Self.allowedSource(url, system: current.systemDomain, home: home, uid: uid),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["Label"] as? String == label else { throw StartupError.changed }
            if enabled && !current.systemDomain && !StartupServicePolicy.supportsCurrentSession(plist) {
                throw StartupError.unavailable(String(localized: "This service is limited to another session, such as the login screen, and cannot be loaded in the current desktop session."))
            }
            if current.systemDomain {
                try await PrivilegedEnergyHelper.shared.setStartupDaemonEnabled(enabled, sourcePath: url.path, label: label)
            } else {
                try StartupServiceAction.apply(enabled: enabled, domain: "gui/\(uid)", label: label, path: url.path) {
                    try run("/bin/launchctl", $0)
                }
            }
        default: throw StartupError.unsupported
        }
    }

    static func allowedSource(_ url: URL, system: Bool, home: URL, uid: Int) -> Bool {
        let url = url.standardizedFileURL
        guard url.pathExtension == "plist", url.resolvingSymlinksInPath().path == url.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let mode = attrs[.posixPermissions] as? NSNumber else { return false }
        let parent = url.deletingLastPathComponent().path
        if system { return parent == "/Library/LaunchDaemons" && owner.intValue == 0 && mode.intValue & 0o022 == 0 }
        if parent == home.appendingPathComponent("Library/LaunchAgents").path {
            return owner.intValue == uid && mode.intValue & 0o022 == 0
        }
        if parent == "/Library/LaunchAgents" { return owner.intValue == 0 && mode.intValue & 0o022 == 0 }
        if let app = StartupValidation.appURL(containing: url),
           parent == app.appendingPathComponent("Contents/Library/LaunchAgents").path {
            return [0, uid].contains(owner.intValue) && mode.intValue & 0o022 == 0
        }
        return false
    }

    private func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 12) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["LANG"] = "C"
        process.environment = environment
        try process.run()
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); stop.cancel()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw StartupError.unavailable(String(output.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
