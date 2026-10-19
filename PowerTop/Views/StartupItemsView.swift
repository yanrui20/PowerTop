import SwiftUI
import ServiceManagement

struct StartupItemsView: View {
    let controller: StartupItemsController
    var onChange: () -> Void = {}
    var allowChanges = true
    @State private var expandedGroups: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(String(localized: "Search applications or startup files"), text: Binding(
                    get: { controller.query }, set: { controller.query = $0 }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small) }
                Button(String(localized: "Refresh")) { Task { await controller.refresh(); onChange() } }
                    .disabled(controller.isBusy)
                Button(String(localized: "System Login Settings")) { SMAppService.openSystemSettingsLoginItems() }
            }
            Text(String(localized: "Background services load immediately when enabled and unload when disabled. Login applications only change their login registration."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let feedback = controller.feedback { Text(feedback).font(.caption).foregroundStyle(.green) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if controller.groups.isEmpty && !controller.isLoading {
                        Text(String(localized: "No matching startup items.")).foregroundStyle(.secondary).padding()
                    }
                    ForEach(controller.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            groupHeader(group)
                            if expandedGroups.contains(group.id) {
                            ForEach(StartupKind.allCases, id: \.self) { kind in
                                let children = group.items.filter { $0.kind == kind }
                                if !children.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(kind.title) · \(children.count)")
                                            .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                                        ForEach(children) { item in startupRow(item) }
                                    }
                                    .padding(.top, 8).padding(.leading, 20)
                                }
                            }
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if !controller.warnings.isEmpty {
                DisclosureGroup(String(localized: "Some items could not be read")) {
                    Text(controller.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(18).frame(minWidth: 760, minHeight: 560)
    }

    private func groupHeader(_ group: StartupGroup) -> some View {
        HStack(spacing: 10) {
            Button {
                if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) }
                else { expandedGroups.insert(group.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                        .font(.caption).frame(width: 10)
                    if let app = group.applicationURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                    } else { Image(systemName: "app.dashed").frame(width: 28, height: 28) }
                    Text(group.name).fontWeight(.medium)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel(group.name + (expandedGroups.contains(group.id) ? String(localized: "Collapse items") : String(localized: "Expand all items")))
            Text(group.status).font(.caption).fontWeight(.medium)
                .foregroundStyle(statusColor(group.state)).padding(.horizontal, 9).padding(.vertical, 4)
                .background(statusColor(group.state).opacity(0.12), in: Capsule())
            Text(String(format: String(localized: "%d items"), group.items.count))
                .font(.caption).foregroundStyle(.secondary).frame(width: 48)
            Toggle(String(localized: "All startup items") + ": " + group.name, isOn: Binding(
                get: { group.allToggleableEnabled }, set: { enabled in
                    Task { await controller.setEnabled(enabled, group: group); onChange() }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(controller.isBusy || !allowChanges || group.toggleableItems.isEmpty)
                .help(String(localized: "Enable or disable all controllable items in this application. System-managed items keep their own settings."))
        }
    }

    private func statusColor(_ state: StartupGroupState) -> Color {
        switch state {
        case .enabled: return .green
        case .partial: return .blue
        case .disabled, .unknown: return .secondary
        }
    }

    private func startupRow(_ item: StartupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind == .loginApp ? "app" : "doc.text").frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.sourceTitle).lineLimit(1).truncationMode(.middle).help(item.sourceURL?.path ?? item.name)
                if let label = item.label { Text(label).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let path = item.sourceURL?.path {
                    Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                if let explanation = item.explanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                if let url = item.sourceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: { Image(systemName: "magnifyingglass") }
            .help(String(localized: "Show Original File in Finder"))
            .accessibilityLabel(String(localized: "Show Original File in Finder") + ": " + item.sourceTitle)
            .disabled(item.sourceURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
            if item.state == .unloaded {
                Text(String(localized: "Not Loaded")).font(.caption).foregroundStyle(.secondary)
            } else if item.state == .unknown {
                Text(String(localized: "Status Unavailable")).font(.caption).foregroundStyle(.secondary)
            }
            if item.management.canToggle {
                if controller.changingItemID == item.id { ProgressView().controlSize(.small) }
                Toggle(item.name, isOn: Binding(get: { item.switchIsOn }, set: { value in
                    Task { await controller.setEnabled(value, item: item); onChange() }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(controller.isBusy || !allowChanges || item.state == .unknown)
                .help(String(localized: "Enable or disable this startup item"))
            } else if item.management == .systemSettings {
                Button(String(localized: "System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            } else {
                Toggle(item.name, isOn: .constant(item.switchIsOn))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(true)
            }
        }
        .padding(.vertical, 7)
    }
}
