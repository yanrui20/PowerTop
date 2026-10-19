import SwiftUI

struct PowerRowView: View {
    /// Shared with popover metric bar rows for left-edge alignment.
    static let iconWidth: CGFloat = 18

    let icon: String
    let iconColor: Color
    let label: String
    let value: String
    var wrapsValue: Bool = false
    var valueHelp: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: Self.iconWidth)
                .padding(.top, 1)

            if wrapsValue {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(value)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)

                Text(value)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .help(valueHelp ?? "")
            }
        }
        .font(.system(size: 12))
        .help(valueHelp ?? "")
    }
}
