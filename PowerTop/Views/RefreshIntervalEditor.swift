import SwiftUI

/// The field exists only during explicit editing, so opening the panel cannot
/// put a hidden text editor into the responder chain.
struct RefreshIntervalEditor: View {
    let monitor: PowerMonitor
    @State private var isEditing = false
    @State private var draft = ""
    @State private var hasError = false
    @State private var didApply = false
    @FocusState private var fieldFocused: Bool

    private var currentInterval: String {
        monitor.updateInterval.formatted(.number.grouping(.never))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(String(localized: "Refresh Interval"))
                if isEditing {
                    TextField("2", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 45)
                        .focused($fieldFocused)
                        .accessibilityIdentifier("refresh-interval-input")
                        .accessibilityLabel(String(localized: "Refresh Interval"))
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
                    .accessibilityIdentifier("refresh-interval-edit")
                    .accessibilityLabel(String(localized: "Edit refresh interval"))
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
                    .accessibilityIdentifier("refresh-interval-apply")
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
        .help(String(localized: "Each interval requests a new system sample. Sampling pauses during sleep; overlapping requests are combined."))
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
        monitor.updateInterval = value
        fieldFocused = false
        isEditing = false
        hasError = false
        draft = currentInterval
        didApply = true
        monitor.refreshNow()
    }
}
