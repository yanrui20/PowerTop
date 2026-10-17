import AppKit
import Foundation
import Observation
import Darwin

struct SignificantEnergyApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
}

struct EnergyAppRecord: Equatable, Sendable {
    let bundleID: String
    let displayName: String
}

enum EnergyAppParser {
    static func parse(_ dictionary: [String: Any]) throws -> [EnergyAppRecord] {
        guard let identifiers = dictionary["bundle_identifiers"] as? [String] else {
            throw EnergyModeError.unavailable
        }
        let responsible = dictionary["responsible_bundle_identifiers"] as? [String] ?? []
        let names = dictionary["display_names"] as? [String] ?? []
        var seen = Set<String>()
        return identifiers.enumerated().compactMap { index, identifier in
            let owner = index < responsible.count && !responsible[index].isEmpty ? responsible[index] : identifier
            guard !owner.isEmpty, seen.insert(owner).inserted else { return nil }
            return EnergyAppRecord(bundleID: owner, displayName: index < names.count ? names[index] : "")
        }
    }
}

/// Uses the same systemstats query as Control Center on macOS 26; never substitutes a CPU ranking.
/// This is a private read-only interface. Missing symbols/data are explicitly reported as unavailable.
actor SystemEnergyAppReader {
    private let library = dlopen("/usr/lib/libsystemstats.dylib", RTLD_LAZY | RTLD_LOCAL)
    func read() throws -> [EnergyAppRecord] {
        guard let library, let symbol = dlsym(library, "systemstats_get_top_coalitions") else {
            throw EnergyModeError.unavailable
        }
        typealias Query = @convention(c) (UInt64, UInt32, Double) -> Unmanaged<CFDictionary>?
        let query = unsafeBitCast(symbol, to: Query.self)
        // Observed Control Center defaults: 120-second window, top 5, 500 * window threshold.
        guard let result = query(120, 5, 60_000)?.takeUnretainedValue() as? [String: Any] else {
            throw EnergyModeError.unavailable
        }
        return try EnergyAppParser.parse(result)
    }
}

@MainActor
@Observable
final class SignificantEnergyApps {
    private(set) var apps: [SignificantEnergyApp] = []
    private(set) var isLoading = false
    private(set) var isAvailable = false
    private(set) var hasLoaded = false
    private let reader = SystemEnergyAppReader()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            let records = try await reader.read()
            apps = records.compactMap { record in
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleID).first
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.bundleID)
                // System coalitions without an application are not user-facing app entries.
                guard running != nil || url != nil else { return nil }
                let name = running?.localizedName ?? (url.map {
                    FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
                }) ?? (record.displayName.isEmpty ? record.bundleID : record.displayName)
                let icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                return SignificantEnergyApp(id: record.bundleID, name: name, icon: icon)
            }
            isAvailable = true
        } catch {
            apps = []
            isAvailable = false
        }
    }

    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}
