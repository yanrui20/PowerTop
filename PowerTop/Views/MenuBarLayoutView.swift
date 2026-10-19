import SwiftUI

struct MenuBarLayoutView: View {
    let monitor: PowerMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Arrange items from left to right. Hidden items keep their position."))
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(Array(monitor.menuBarOrder.enumerated()), id: \.element) { index, item in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                        Text(item.title)
                        Spacer()
                        Toggle(String(localized: "Show"), isOn: Binding(
                            get: { monitor.isMenuBarItemEnabled(item) },
                            set: { monitor.setMenuBarItem(item, enabled: $0) }))
                            .labelsHidden().accessibilityLabel(item.title + " " + String(localized: "Show"))
                            .toggleStyle(.switch).controlSize(.small)
                        Button { monitor.moveMenuBarItem(item, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless).accessibilityLabel(item.title + " " + String(localized: "Move Left"))
                            .disabled(index == 0).help(String(localized: "Move Left"))
                        Button { monitor.moveMenuBarItem(item, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless).accessibilityLabel(item.title + " " + String(localized: "Move Right"))
                            .disabled(index == monitor.menuBarOrder.count - 1).help(String(localized: "Move Right"))
                    }
                    .padding(.vertical, 4)
                }
                .onMove { indices, destination in monitor.moveMenuBarItems(from: indices, to: destination) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Picker(String(localized: "Memory Accounting"), selection: Binding(
                    get: { monitor.memoryAccounting }, set: { monitor.memoryAccounting = $0 })) {
                    ForEach(MemoryAccounting.allCases, id: \.self) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.menu).controlSize(.small)
                Text(monitor.memoryAccounting.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(String(localized: "Changes appear immediately and are saved automatically."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Reset Order")) { monitor.menuBarOrder = MenuBarItemKind.defaultOrder }
            }
        }
        .padding(18).frame(minWidth: 520, minHeight: 460)
    }
}
