import SwiftUI

/// The field exists only during explicit editing, so opening the panel cannot
/// put a hidden text editor into the responder chain.
struct RefreshIntervalEditor: View {
    enum Scope { case battery, resources }
    let monitor: PowerMonitor
    var scope: Scope = .battery
    private var label: String {
        scope == .battery ? String(localized: "Battery Refresh Interval") : String(localized: "Resource Refresh Interval")
    }
    private var identifier: String { scope == .battery ? "refresh-interval" : "resource-refresh-interval" }
    private var interval: TimeInterval { scope == .battery ? monitor.updateInterval : monitor.resourceRefreshInterval }
    private var intervalHelp: String {
        scope == .battery
            ? String(localized: "Each interval requests a new system sample. Sampling pauses during sleep; overlapping requests are combined.")
            : String(localized: "System resources refresh independently of battery sampling.")
    }
    @State private var isEditing = false
    @State private var draft = ""
    @State private var hasError = false
    @State private var didApply = false
    @FocusState private var fieldFocused: Bool

    private var currentInterval: String {
        interval.formatted(.number.grouping(.never))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                if isEditing {
                    TextField("2", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 45)
                        .focused($fieldFocused)
                        .accessibilityIdentifier("\(identifier)-input")
                        .accessibilityLabel(label)
                        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                        .onSubmit { apply() }
                        .onExitCommand { cancel() }
                } else {
                    Button(action: beginEditing) {
                        HStack(spacing: 3) {
                            Text(currentInterval).monospacedDigit()
                            Image(systemName: "pencil").font(.system(size: 9))
                        }
                    }
                    .buttonStyle(.bordered)
                    .focusable(false)
                    .accessibilityIdentifier("\(identifier)-edit")
                    .accessibilityLabel(label)
                }
                Text(String(localized: "Seconds"))
                Spacer(minLength: 2)
                if !isEditing && didApply {
                    Label(String(localized: "Applied"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.system(size: 11))
            .controlSize(.small)
            if isEditing {
                HStack(spacing: 6) {
                    Spacer()
                    Button(String(localized: "Cancel"), action: cancel)
                        .buttonStyle(.bordered)
                    Button(action: apply) {
                        Text(String(localized: "Apply"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier)-apply")
                }
                .font(.system(size: 11))
                .controlSize(.small)
            }
            if hasError {
                Text(String(localized: "Enter an interval from 1 to 300 seconds."))
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(intervalHelp)
        .onChange(of: monitor.isPopoverVisible) { _, visible in
            if !visible { cancel(); didApply = false }
        }
        .onDisappear { cancel(); didApply = false }
    }

    private func beginEditing() {
        draft = currentInterval
        hasError = false
        didApply = false
        isEditing = true
    }

    private func cancel() {
        fieldFocused = false
        isEditing = false
        draft = currentInterval
        hasError = false
    }

    private func apply() {
        guard isEditing else { return }
        let decimal = Locale.current.decimalSeparator ?? "."
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: decimal, with: ".")
        guard let value = Double(input), value.isFinite,
              PowerMonitor.refreshIntervalRange.contains(value) else {
            hasError = true
            fieldFocused = true
            return
        }
        if scope == .battery { monitor.updateInterval = value }
        else { monitor.resourceRefreshInterval = value }
        fieldFocused = false
        isEditing = false
        hasError = false
        draft = currentInterval
        didApply = true
        if scope == .battery { monitor.refreshNow() }
        else { Task { await monitor.systemMetrics.refresh() } }
    }
}
