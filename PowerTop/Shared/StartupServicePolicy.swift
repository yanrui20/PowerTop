import Foundation
import Darwin

/// Shared validation, repeated inside the privileged process before any change.
enum StartupServicePolicy {
    /// `list` includes registered jobs even when their PID is "-" (waiting, not running).
    static func loadedLabels(_ text: String) -> Set<String>? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first,
              header.split(whereSeparator: \.isWhitespace).map(String.init) == ["PID", "Status", "Label"] else { return nil }
        var result = Set<String>()
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[0] == "-" || Int(fields[0]) != nil,
                  Int(fields[1]) != nil else { return nil }
            result.insert(String(fields[2]))
        }
        return result
    }

    static func supportsCurrentSession(_ plist: [String: Any]) -> Bool {
        guard let value = plist["LimitLoadToSessionType"] else { return true }
        if let name = value as? String { return name == "Aqua" }
        if let names = value as? [String] { return names.contains("Aqua") }
        return false
    }

    static func validLabel(_ label: String) -> Bool {
        !label.hasPrefix("com.apple.") && label != EnergyHelperConstants.service &&
        label.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\\z", options: .regularExpression) != nil
    }

    static func daemonLabel(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.path == path, url.standardizedFileURL.path == path,
              url.deletingLastPathComponent().path == "/Library/LaunchDaemons",
              url.pathExtension == "plist", url.resolvingSymlinksInPath().path == path else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= 1_048_576 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd(),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, validLabel(label) else { return nil }
        return label
    }

    static func validDaemon(path: String, label: String) -> Bool {
        guard validLabel(label), daemonLabel(at: path) == label,
              let files = try? FileManager.default.contentsOfDirectory(atPath: "/Library/LaunchDaemons") else { return false }
        // A launchd override addresses a label; reject ambiguous duplicate files.
        let matches = files.filter { $0.hasSuffix(".plist") }.filter { file in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/Library/LaunchDaemons/" + file)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            return plist["Label"] as? String == label
        }
        return matches.count == 1
    }

    static func backgroundRecords(_ text: String, ownerUID: uid_t) -> String {
        var include = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("Records for UID ") {
                let uid = Int(value.dropFirst("Records for UID ".count).split(separator: " ").first ?? "")
                include = uid.map { [Int(ownerUID), 0, -2].contains($0) } ?? false
            }
            return include
        }.joined(separator: "\n")
    }
}

/// Fixed launchctl operations only. The caller must first validate the source and domain.
enum StartupServiceAction {
    static func apply(enabled: Bool, domain: String, label: String, path: String,
                      run: ([String]) throws -> String) throws {
        _ = try run([enabled ? "enable" : "disable", domain + "/" + label])
        if !enabled {
            guard let loaded = StartupServicePolicy.loadedLabels(try run(["list"])) else {
                throw StartupServiceActionError.unloadUnconfirmed
            }
            if loaded.contains(label) {
                do { _ = try run(["bootout", domain + "/" + label]) }
                catch {
                    // It may already have been removed by its owner during this request.
                    guard StartupServicePolicy.loadedLabels((try? run(["list"])) ?? "")?.contains(label) == false else { throw error }
                }
            }
            guard StartupServicePolicy.loadedLabels(try run(["list"]))?.contains(label) == false else {
                throw StartupServiceActionError.unloadUnconfirmed
            }
            return
        }
        guard let loaded = StartupServicePolicy.loadedLabels(try run(["list"])) else {
            throw StartupServiceActionError.unavailable
        }
        if !loaded.contains(label) {
            do { _ = try run(["bootstrap", domain, path]) }
            catch {
                // Another process may have loaded the same job while we requested it.
                guard StartupServicePolicy.loadedLabels((try? run(["list"])) ?? "")?.contains(label) == true else { throw error }
            }
        }
        guard StartupServicePolicy.loadedLabels(try run(["list"]))?.contains(label) == true else {
            throw StartupServiceActionError.unavailable
        }
    }
}
enum StartupServiceActionError: LocalizedError {
    case unavailable, unloadUnconfirmed
    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "The service could not be confirmed as loaded. Refresh and check its configuration.")
        case .unloadUnconfirmed: return String(localized: "Automatic startup was disabled, but unloading could not be confirmed. Refresh and try again.")
        }
    }
}
