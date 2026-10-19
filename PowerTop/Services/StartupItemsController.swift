import Foundation
import Observation

@MainActor
@Observable
final class StartupItemsController {
    private(set) var items: [StartupItem] = []
    private(set) var warnings: [String] = []
    private(set) var error: String?
    private(set) var feedback: String?
    private(set) var isLoading = false
    private(set) var changingItemID: String?
    var query = ""
    private let backend: any StartupItemsBackend
    init(backend: any StartupItemsBackend = SystemStartupItemsBackend()) { self.backend = backend }
    var isBusy: Bool { isLoading || changingItemID != nil }
    var groups: [StartupGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = items.filter { item in
            query.isEmpty || [item.name, item.applicationName, item.label ?? "", item.sourceURL?.path ?? ""].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
        // Search selects applications, never shrinks the scope of their master switch.
        let groupIDs = Set(matches.map(\.groupID))
        return Dictionary(grouping: items.filter { groupIDs.contains($0.groupID) }, by: \.groupID).map { key, items in
            StartupGroup(id: key, name: items[0].applicationName, applicationURL: items[0].applicationURL,
                         items: items.sorted { $0.sourceTitle.localizedStandardCompare($1.sourceTitle) == .orderedAscending })
        }.sorted { lhs, rhs in
            if lhs.state.sortPriority != rhs.state.sortPriority {
                return lhs.state.sortPriority < rhs.state.sortPriority
            }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            // Keep equal names stable across dictionary enumeration and refreshes.
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
    }
    func refresh() async {
        guard !isBusy else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do { let snapshot = try await backend.read(); items = snapshot.items; warnings = snapshot.warnings }
        catch { self.error = error.localizedDescription }
    }
    func setEnabled(_ enabled: Bool, item: StartupItem) async {
        await apply(enabled, targets: [item], busyID: item.id)
    }
    func setEnabled(_ enabled: Bool, group: StartupGroup) async {
        let targets = items.filter { $0.groupID == group.id && $0.management.canToggle && $0.state != .unknown }
        await apply(enabled, targets: targets, busyID: group.id)
    }
    private func apply(_ enabled: Bool, targets: [StartupItem], busyID: String) async {
        let targets = targets.filter { $0.management.canToggle && $0.state != .unknown && $0.needsChange(to: enabled) }
        guard !isBusy, !targets.isEmpty else { return }
        changingItemID = busyID; error = nil; feedback = nil
        defer { changingItemID = nil }
        var mutationError: Error?
        do { try await backend.setEnabled(enabled, items: targets) }
        catch { mutationError = error }
        do {
            let snapshot = try await backend.read()
            items = snapshot.items; warnings = snapshot.warnings
            if let mutationError { throw mutationError }
            guard targets.allSatisfy({ target in
                guard let actual = items.first(where: { $0.id == target.id }) else { return false }
                return enabled ? actual.state == .enabled
                    : actual.enabled == false && (actual.kind == .loginApp || actual.loaded == false)
            }) else {
                throw StartupError.unavailable(String(localized: "macOS did not confirm the startup-item change."))
            }
            feedback = enabled ? String(localized: "Startup enabled. Supported services are now loaded.")
                : String(localized: "Startup disabled. Supported background services have been unloaded.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
