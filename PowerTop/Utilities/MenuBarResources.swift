import AppKit

/// Two rows per metric keep the shared status item narrow and stable.
struct MenuBarResourceItem: Equatable {
    let top: String
    let bottom: String
    var isNetwork = false
    var showsChargingBadge = false

    var kind: MenuBarItemKind {
        if isNetwork { return .network }
        switch bottom {
        case "BAT": return .battery
        case "PWR": return .power
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
        let result = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: color, .kern: -0.3])
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
        let reference = isNetwork ? "↑999M/s" : (kind == .power ? "99W" : "100%")
        let baseline = text(reference, font: topFont, color: .labelColor, numeric: true).size().width
        let badgeWidth: CGFloat = showsChargingBadge ? 4.5 : 0
        return ceil(max(baseline + badgeWidth, topWidth + badgeWidth, bottomWidth))
    }

    func draw(at x: CGFloat, color: NSColor) {
        for (value, font, y, numeric) in [(top, topFont, CGFloat(9), true), (bottom, bottomFont, CGFloat(isNetwork ? -1 : 0), isNetwork)] {
            let attributed = text(value, font: font, color: color, numeric: numeric)
            let hasBadge = showsChargingBadge && y == 9
            let contentWidth = attributed.size().width + (hasBadge ? 4.5 : 0)
            let origin = x + (width - contentWidth) / 2
            attributed.draw(at: NSPoint(x: origin, y: y))
            if hasBadge, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color])) {
                bolt.draw(in: NSRect(x: origin + attributed.size().width + 0.5, y: 13, width: 4, height: 7))
            }
        }
    }
}

extension MenuBarPresentation {
    var needsCompositeImage: Bool { batteryPercent != nil || !title.isEmpty || !resources.isEmpty }
    var batteryColumn: MenuBarResourceItem? {
        batteryPercent.map { .init(top: "\($0)%", bottom: "BAT", showsChargingBadge: chargingBadge == .battery) }
    }
    var powerColumn: MenuBarResourceItem? {
        title.isEmpty ? nil : .init(top: title, bottom: "PWR", showsChargingBadge: chargingBadge == .afterPower)
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
    /// Apply mode color only to battery/power columns; resource columns use normal menu text.
    /// The controller resolves normalColor from the status button's appearance.
    func compactStatusImage(normalColor: NSColor = .labelColor) -> NSImage? {
        guard needsCompositeImage else { return symbolImage() }
        let battery = batteryColumn == nil ? symbolImage() : nil
        let energyColor = tint.color ?? normalColor
        let order = visibleItemOrder
        func width(_ kind: MenuBarItemKind) -> CGFloat {
            switch kind {
            case .battery: return batteryColumn?.width ?? battery?.size.width ?? 0
            case .power: return powerColumn?.width ?? 0
            default: return resources.first { $0.kind == kind }?.width ?? 0
            }
        }
        let total = order.map(width).reduce(0, +) + CGFloat(max(0, order.count - 1))
        let image = NSImage(size: NSSize(width: total, height: 22), flipped: false) { rect in
            var x: CGFloat = 0
            for kind in order {
                switch kind {
                case .battery:
                    if let column = batteryColumn {
                        column.draw(at: x, color: energyColor)
                    } else if let battery {
                        let frame = NSRect(x: x, y: rect.midY - battery.size.height / 2, width: battery.size.width, height: battery.size.height)
                        battery.draw(in: frame)
                        if battery.isTemplate {
                            normalColor.setFill()
                            frame.fill(using: .sourceAtop)
                        }
                    }
                case .power:
                    powerColumn?.draw(at: x, color: energyColor)
                default: resources.first { $0.kind == kind }?.draw(at: x, color: normalColor)
                }
                x += width(kind) + 1
            }
            return true
        }
        // Template rendering would tint every column, including normal text.
        image.isTemplate = false
        return Self.rasterizedStatusImage(image)
    }
}

extension MenuBarPresentation {
    /// Materialize both display scales once per value/color change. A live
    /// NSCustomImageRep otherwise reruns text layout for every replicated menu bar.
    static func rasterizedStatusImage(_ source: NSImage) -> NSImage {
        let result = NSImage(size: source.size)
        for scale in [1.0, 2.0] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(source.size.width * scale)), pixelsHigh: Int(ceil(source.size.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = source.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            source.draw(in: NSRect(origin: .zero, size: source.size), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            result.addRepresentation(bitmap)
        }
        guard !result.representations.isEmpty else { return source }
        result.isTemplate = source.isTemplate
        return result
    }
}
