import Foundation

enum StartupKind: String, CaseIterable, Sendable {
    case loginApp, userAgent, sharedAgent, daemon, bundledService
    var title: String {
        switch self {
        case .loginApp: return String(localized: "Login Applications")
        case .userAgent: return String(localized: "User Background Items")
        case .sharedAgent: return String(localized: "Shared Background Items")
        case .daemon: return String(localized: "System Background Services")
        case .bundledService: return String(localized: "Bundled Background Items")
        }
    }
}
enum StartupManagement: Sendable {
    case launchd, legacyLogin, ownApp, systemSettings, readOnly
    var canToggle: Bool { self == .launchd || self == .legacyLogin || self == .ownApp }
}
struct StartupItem: Identifiable, Sendable {
    let id: String
    let name: String
    let applicationName: String
    let applicationURL: URL?
    let sourceURL: URL?
    let executableURL: URL?
    let kind: StartupKind
    var management: StartupManagement
    var enabled: Bool?
    var explanation: String?
    var label: String?
    var systemDomain = false
    var loaded: Bool? = nil
    var canLoadInCurrentSession = true
    var state: StartupItemState {
        // Login applications use login registration, not process liveness.
        if kind == .loginApp {
            guard let enabled else { return .unknown }
            return enabled ? .enabled : .disabled
        }
        // Match Lemon's service switch: registration alone determines "on".
        // A loaded job waiting for a trigger is on even without a PID.
        guard let loaded else { return .unknown }
        if loaded { return .enabled }
        guard let enabled else { return .unknown }
        return enabled ? .unloaded : .disabled
    }
    var switchIsOn: Bool { state == .enabled }
    func needsChange(to enabled: Bool) -> Bool {
        enabled ? state != .enabled : self.enabled != false || (kind != .loginApp && loaded != false)
    }
    var groupID: String { applicationURL?.path ?? applicationName }
    var sourceTitle: String { sourceURL?.lastPathComponent ?? name }
}
enum StartupItemState { case enabled, unloaded, disabled, unknown }
struct StartupSnapshot: Sendable {
    var items: [StartupItem]
    var warnings: [String] = []
}
struct StartupGroup: Identifiable {
    let id: String
    let name: String
    let applicationURL: URL?
    let items: [StartupItem]
    var toggleableItems: [StartupItem] { items.filter { $0.management.canToggle && $0.state != .unknown } }
    var allToggleableEnabled: Bool { !toggleableItems.isEmpty && toggleableItems.allSatisfy(\.switchIsOn) }
    var state: StartupGroupState {
        if items.contains(where: { $0.state == .unknown }) { return .unknown }
        let enabled = items.filter(\.switchIsOn).count
        return enabled == items.count ? .enabled : enabled == 0 ? .disabled : .partial
    }
    var status: String { state.title }
}
enum StartupGroupState {
    case enabled, partial, disabled, unknown
    var sortPriority: Int {
        switch self {
        case .enabled: return 0
        case .partial: return 1
        case .disabled: return 2
        case .unknown: return 3
        }
    }
    var title: String {
        switch self {
        case .enabled: return String(localized: "All Enabled")
        case .partial: return String(localized: "Partly Enabled")
        case .disabled: return String(localized: "All Disabled")
        case .unknown: return String(localized: "Status Unavailable")
        }
    }
}
struct BackgroundTaskRecord: Sendable {
    let uid: Int
    let fields: [String: String]
    var identifier: String { fields["Identifier"] ?? "" }
    var type: String { fields["Type"] ?? "" }
    var name: String { fields["Name"] ?? identifier }
    var enabled: Bool? {
        guard let disposition = fields["Disposition"] else { return nil }
        if disposition.contains("disabled") || disposition.contains("disallowed") { return false }
        return disposition.contains("enabled") && disposition.contains("allowed") ? true : nil
    }
    var permissionBlocked: Bool { fields["Disposition"]?.contains("disallowed") == true }
    static func parse(_ text: String, uid: Int) -> [BackgroundTaskRecord] {
        var records: [BackgroundTaskRecord] = [], current: [String: String] = [:]
        var sectionUID: Int?
        func flush() {
            if let sectionUID, [uid, 0, -2].contains(sectionUID), current["Identifier"] != nil {
                records.append(.init(uid: sectionUID, fields: current))
            }
            current = [:]
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                flush()
                sectionUID = Int(line.dropFirst("Records for UID ".count).split(separator: " ").first ?? "")
            } else if line.hasPrefix("#"), line.hasSuffix(":"), !line.contains(" ") {
                flush()
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value != "(null)", !value.isEmpty { current[key] = value }
            }
        }
        flush()
        return records
    }
    func fileURL(key: String, records: [BackgroundTaskRecord]) -> URL? {
        guard let value = fields[key], value != "(null)" else { return nil }
        if value.hasPrefix("file:"), let url = URL(string: value), url.isFileURL { return url.standardizedFileURL }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        if let parent = fields["Parent Identifier"],
           let base = records.first(where: { $0.identifier == parent && $0.fields["URL"]?.hasPrefix("file:") == true }),
           let urlString = base.fields["URL"], let url = URL(string: urlString) {
            return url.appendingPathComponent(value).standardizedFileURL
        }
        return nil
    }
}

struct StartupOwner: Sendable {
    let url: URL
    let bundleID: String
    let teamID: String
}

enum StartupValidation {
    static func ownerURL(label: String, teamID: String?, candidates: [StartupOwner]) -> URL? {
        guard let teamID else { return nil }
        let label = label.lowercased()
        let matches = candidates.filter {
            $0.teamID == teamID && (label == $0.bundleID.lowercased() || label.hasPrefix($0.bundleID.lowercased() + "."))
        }
        guard let length = matches.map({ $0.bundleID.count }).max() else { return nil }
        let paths = Set(matches.filter { $0.bundleID.count == length }.map(\.url))
        return paths.count == 1 ? paths.first : nil
    }

    static func validLabel(_ label: String) -> Bool {
        !label.hasPrefix("com.apple.") && label.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\\z", options: .regularExpression) != nil
    }
    static func disabledOverrides(_ text: String) -> [String: Bool] {
        var values: [String: Bool] = [:]
        let pattern = #""([^"\n]+)"\s*=>\s*(enabled|disabled|true|false)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return values }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let state = ns.substring(with: match.range(at: 2))
            values[ns.substring(with: match.range(at: 1))] = state == "disabled" || state == "true"
        }
        return values
    }
    static func appURL(containing url: URL?) -> URL? {
        guard let url else { return nil }
        let components = url.standardizedFileURL.pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])), isDirectory: true)
    }
}

enum StartupError: LocalizedError {
    case unavailable(String), changed, unsupported, approvalRequired
    var errorDescription: String? {
        switch self {
        case .unavailable(let text): return text
        case .changed: return String(localized: "This startup item changed. Refresh the list and try again.")
        case .unsupported: return String(localized: "Manage this item in System Settings or its owning application.")
        case .approvalRequired: return String(localized: "Approve this login item in System Settings to finish enabling it.")
        }
    }
}
