import AppKit

struct MenuBarPresentation: Equatable {
    enum Tint: Equatable {
        case system, yellow, white

        var color: NSColor? {
            switch self {
            case .system: return nil
            case .yellow: return .systemYellow
            case .white: return .white
            }
        }
    }

    enum ChargingBadge: Equatable { case none, battery, afterPower }
    let batteryPercent: Int?
    let chargingBadge: ChargingBadge
    let tint: Tint
    let symbol: String?
    let title: String
    let resources: [MenuBarResourceItem]
    let itemOrder: [MenuBarItemKind]

    init(available: Bool, percent: Int, charging: Bool, onAC: Bool,
         showBattery: Bool, showPower: Bool, powerText: String, mode: EnergyMode? = nil,
         resources: [MenuBarResourceItem] = [], itemOrder: [MenuBarItemKind] = MenuBarItemKind.defaultOrder) {
        self.itemOrder = MenuBarItemKind.normalized(itemOrder.map(\.rawValue))
        self.resources = resources
        let hasBatterySymbol = showBattery || (!showPower && resources.isEmpty)
        // An unavailable reading must not imply a particular energy mode.
        tint = !available ? .system : (mode == .low ? .yellow : (mode == .high ? .white : .system))
        batteryPercent = available && showBattery ? min(100, max(0, percent)) : nil
        chargingBadge = !available || !charging || !onAC ? .none
            : (hasBatterySymbol ? .battery : (showPower ? .afterPower : .none))
        guard available else {
            symbol = showBattery || showPower || resources.isEmpty ? "exclamationmark.triangle" : nil
            title = ""
            return
        }
        title = showPower ? powerText : ""
        symbol = hasBatterySymbol ? "battery.50" : nil
    }
    var titleBadgeIndex: Int? {
        switch chargingBadge {
        case .afterPower: return title.count
        default: return nil
        }
    }

    func attributedTitle(font: NSFont, normalColor: NSColor? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let normalColor { attributes[.foregroundColor] = normalColor }
        let result = NSMutableAttributedString(string: title, attributes: attributes)
        if let index = titleBadgeIndex {
            let attachment = NSTextAttachment()
            attachment.image = Self.symbolImage("bolt.fill", tint: .system)
            attachment.bounds = NSRect(x: 0, y: 1.5, width: 4, height: 7)
            let badge = NSMutableAttributedString(string: "", attributes: attributes)
            badge.append(NSAttributedString(attachment: attachment))
            result.insert(badge, at: index)
        }
        return result
    }

    static func symbolImage(_ name: String, tint: Tint) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let color = tint.color {
            let colored = image.withSymbolConfiguration(.init(paletteColors: [color]))
            colored?.isTemplate = false
            return colored
        }
        image.isTemplate = true
        return image
    }

    /// A fixed-width outline keeps 0–100 stable in the menu bar. The number is
    /// the percentage; omit the percent sign so three digits remain legible.
    private func numberedBatteryImage(percent: Int) -> NSImage {
        let charging = chargingBadge == .battery
        let image = NSImage(size: NSSize(width: 30, height: 17), flipped: false) { canvas in
            let color = tint.color ?? .black
            color.setStroke()
            let body = NSRect(x: 0.75, y: canvas.midY - 6.75, width: 25.5, height: 13.5)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.25
            outline.stroke()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 27.5, y: body.midY - 3, width: 1.75, height: 6), xRadius: 0.8, yRadius: 0.8).fill()
            let number = NSAttributedString(string: String(percent), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: color
            ])
            let size = number.size()
            let boltWidth: CGFloat = 4
            let gap: CGFloat = 0.75
            let contentWidth = size.width + (charging ? gap + boltWidth : 0)
            let numberX = body.midX - contentWidth / 2
            number.draw(at: NSPoint(x: numberX, y: body.midY - size.height / 2))
            if charging {
                Self.symbolImage("bolt.fill", tint: tint)?.draw(in: NSRect(
                    x: numberX + size.width + gap, y: body.midY - 3.5,
                    width: boltWidth, height: 7))
            }
            return true
        }
        image.isTemplate = tint == .system
        image.accessibilityDescription = "\(percent)%"
        return image
    }

    func symbolImage() -> NSImage? {
        guard let symbol else { return nil }
        if let batteryPercent { return numberedBatteryImage(percent: batteryPercent) }
        guard chargingBadge == .battery else { return Self.symbolImage(symbol, tint: tint) }
        // Keep the battery outline; hang a small bolt from its lower-right corner.
        let image = NSImage(size: NSSize(width: 28, height: 16), flipped: false) { rect in
            Self.symbolImage(symbol, tint: tint)?.draw(in: NSRect(x: 0, y: 4, width: 23, height: 11))
            Self.symbolImage("bolt.fill", tint: tint)?.draw(in: NSRect(x: 22, y: 0, width: 6, height: 10))
            return true
        }
        image.isTemplate = tint == .system
        return image
    }
}
