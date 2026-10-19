import AppKit

/// Two rows per metric keep the shared status item narrow and stable.
struct MenuBarResourceItem: Equatable {
    let top: String
    let bottom: String
    var isNetwork = false

    var kind: MenuBarItemKind {
        if isNetwork { return .network }
        switch bottom {
        case "CPU": return .cpu
        case "GPU": return .gpu
        case "MEM": return .memory
        case "TEMP": return .temperature
        case "RPM": return .fans
        default: return .disk
        }
    }

    static func percent(_ value: Double?, label: String) -> Self {
        .init(top: SystemMetricsSnapshot.percentText(value), bottom: label)
    }

    static func compactRate(_ rate: Double?) -> String {
        guard var rate, rate.isFinite, rate >= 0 else { return "—" }
        let units = ["B/s", "K/s", "M/s", "G/s", "T/s"]
        var unit = 0
        while rate >= 999.5 && unit < units.count - 1 { rate /= 1000; unit += 1 }
        return String(format: unit > 0 && rate < 10 ? "%.1f%@" : "%.0f%@", rate, units[unit])
    }

    static func network(upload: Double?, download: Double?) -> Self {
        .init(top: "↑" + compactRate(upload), bottom: "↓" + compactRate(download), isNetwork: true)
    }

    var topFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
    var bottomFont: NSFont { .monospacedDigitSystemFont(ofSize: isNetwork ? 11 : 7, weight: .medium) }
    private func text(_ value: String, font: NSFont, color: NSColor, numeric: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        if numeric {
            // Keep values prominent; units and direction arrows take less horizontal space.
            for (offset, character) in value.utf16.enumerated() where !(48...57).contains(character) && character != 46 && character != 8212 {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: 7.5, weight: .medium), range: NSRange(location: offset, length: 1))
            }
        }
        return result
    }
    var width: CGFloat {
        let topWidth = text(top, font: topFont, color: .labelColor, numeric: true).size().width
        let bottomWidth = text(bottom, font: bottomFont, color: .labelColor, numeric: isNetwork).size().width
        let baseline = text(isNetwork ? "↑999M/s" : "100%", font: topFont, color: .labelColor, numeric: true).size().width
        return ceil(max(baseline, topWidth, bottomWidth))
    }

    func draw(at x: CGFloat, color: NSColor) {
        for (value, font, y, numeric) in [(top, topFont, CGFloat(9), true), (bottom, bottomFont, CGFloat(isNetwork ? -1 : 0), isNetwork)] {
            let attributed = text(value, font: font, color: color, numeric: numeric)
            attributed.draw(at: NSPoint(x: x + (width - attributed.size().width) / 2, y: y))
        }
    }
}

extension MenuBarPresentation {
    var needsCompositeImage: Bool {
        !resources.isEmpty || (symbol != nil && !title.isEmpty &&
            itemOrder.firstIndex(of: .power)! < itemOrder.firstIndex(of: .battery)!)
    }
    var visibleItemOrder: [MenuBarItemKind] {
        itemOrder.filter { kind in
            switch kind {
            case .battery: return symbol != nil
            case .power: return !title.isEmpty
            default: return resources.contains { $0.kind == kind }
            }
        }
    }
    /// Keep normal menu text independent of the battery's explicit mode color.
    /// The controller resolves normalColor from the status button's appearance.
    func compactStatusImage(normalColor: NSColor = .labelColor) -> NSImage? {
        guard needsCompositeImage else { return symbolImage() }
        let battery = symbolImage()
        let power = attributedTitle(font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), normalColor: normalColor)
        let order = visibleItemOrder
        func width(_ kind: MenuBarItemKind) -> CGFloat {
            switch kind {
            case .battery: return battery?.size.width ?? 0
            case .power: return ceil(power.size().width)
            default: return resources.first { $0.kind == kind }?.width ?? 0
            }
        }
        let total = order.map(width).reduce(0, +) + CGFloat(max(0, order.count - 1))
        let image = NSImage(size: NSSize(width: total, height: 22), flipped: false) { rect in
            var x: CGFloat = 0
            for kind in order {
                switch kind {
                case .battery:
                    if let battery {
                        let frame = NSRect(x: x, y: rect.midY - battery.size.height / 2, width: battery.size.width, height: battery.size.height)
                        battery.draw(in: frame)
                        if battery.isTemplate {
                            normalColor.setFill()
                            frame.fill(using: .sourceAtop)
                        }
                    }
                case .power:
                    power.draw(at: NSPoint(x: x, y: rect.midY - power.size().height / 2))
                default: resources.first { $0.kind == kind }?.draw(at: x, color: normalColor)
                }
                x += width(kind) + 1
            }
            return true
        }
        // Template rendering would tint every column, including normal text.
        image.isTemplate = false
        return image
    }
}
