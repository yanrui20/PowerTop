import SwiftUI

struct MenuBarLabelView: View {
    let monitor: PowerMonitor
    var body: some View {
        let presentation = monitor.menuBarPresentation
        HStack(spacing: 2) {
            if let image = presentation.symbolImage() { Image(nsImage: image) }
            if let index = presentation.titleBadgeIndex {
                Text(String(presentation.title.prefix(index))).monospacedDigit()
                Image(systemName: "bolt.fill").font(.system(size: 9))
                Text(String(presentation.title.dropFirst(index))).monospacedDigit()
            } else if !presentation.title.isEmpty {
                Text(presentation.title).monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(presentation.tint.color.map { Color(nsColor: $0) } ?? .primary)
    }
}
