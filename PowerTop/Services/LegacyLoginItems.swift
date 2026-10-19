import Foundation
import CoreServices

struct LegacyLoginRecord: Sendable {
    let name: String
    let url: URL
    let enabled: Bool
    var hidden = false
}

/// macOS still exposes classic session login items through SharedFileList.
/// Keep the deprecated API isolated; verify every mutation by reading it back.
@MainActor
enum LegacyLoginItems {
    private static let backupKey = "PowerTop.DisabledLoginApplications"
    static func records() throws -> [LegacyLoginRecord] {
        let active = try activeItems().map { $0.record }
        let saved = UserDefaults.standard.array(forKey: backupKey) as? [[String: Any]] ?? []
        let disabled = saved.compactMap { value -> LegacyLoginRecord? in
            guard let path = value["path"] as? String, path.hasPrefix("/"),
                  !active.contains(where: { $0.url.path == path }) else { return nil }
            return .init(name: value["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent,
                         url: URL(fileURLWithPath: path), enabled: false, hidden: value["hidden"] as? Bool ?? false)
        }
        return active + disabled
    }

    static func setEnabled(_ enabled: Bool, url: URL) throws {
        let active = try activeItems()
        guard let list = makeList() else { throw StartupError.unsupported }
        var saved = UserDefaults.standard.array(forKey: backupKey) as? [[String: Any]] ?? []
        if enabled {
            if active.contains(where: { $0.record.url == url }) { return }
            guard FileManager.default.fileExists(atPath: url.path),
                  let record = saved.first(where: { $0["path"] as? String == url.path }) else { throw StartupError.changed }
            let properties = [kLSSharedFileListLoginItemHidden.takeUnretainedValue() as String: record["hidden"] as? Bool ?? false] as CFDictionary
            guard LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast.takeUnretainedValue(), nil, nil,
                url as CFURL, properties, nil) != nil else { throw StartupError.unsupported }
        } else {
            guard let item = active.first(where: { $0.record.url == url }) else { throw StartupError.changed }
            // Save the exact app URL before removal, so disabling remains reversible.
            saved.removeAll { $0["path"] as? String == url.path }
            saved.append(["path": url.path, "name": item.record.name, "hidden": item.record.hidden])
            UserDefaults.standard.set(saved, forKey: backupKey)
            guard LSSharedFileListItemRemove(list, item.item) == noErr else { throw StartupError.unsupported }
        }
        let actual = try activeItems().contains { $0.record.url == url }
        guard actual == enabled else { throw StartupError.unavailable(String(localized: "macOS did not confirm the startup-item change.")) }
        if enabled {
            saved.removeAll { $0["path"] as? String == url.path }
            UserDefaults.standard.set(saved, forKey: backupKey)
        }
    }

    private static func makeList() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    }
    private static func activeItems() throws -> [(item: LSSharedFileListItem, record: LegacyLoginRecord)] {
        var seed: UInt32 = 0
        guard let list = makeList(), let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] else {
            throw StartupError.unavailable(String(localized: "Classic login items are currently unavailable."))
        }
        return snapshot.compactMap { item in
            let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL?, url.isFileURL else { return nil }
            let name = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            let hidden = LSSharedFileListItemCopyProperty(item, kLSSharedFileListLoginItemHidden.takeUnretainedValue())?.takeRetainedValue() as? Bool ?? false
            return (item, .init(name: name, url: url.standardizedFileURL, enabled: true, hidden: hidden))
        }
    }
}
