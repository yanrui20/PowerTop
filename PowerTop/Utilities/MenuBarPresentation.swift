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

    enum ChargingBadge: Equatable { case none, battery, afterPercentage, afterPower }
    let chargingBadge: ChargingBadge
    let tint: Tint
    let symbol: String?
    let title: String

    init(available: Bool, percent: Int, charging: Bool, onAC: Bool,
         showBattery: Bool, showPower: Bool, powerText: String, mode: EnergyMode? = nil) {
        // An unavailable reading must not imply a particular energy mode.
        tint = !available ? .system : (mode == .low ? .yellow : (mode == .high ? .white : .system))
        chargingBadge = !available || !charging || !onAC ? .none
            : (showBattery ? .afterPercentage : (showPower ? .afterPower : .battery))
        guard available else {
            symbol = "exclamationmark.triangle"
            title = ""
            return
        }
        let percent = min(100, max(0, percent))
        var parts: [String] = []
        if showBattery { parts.append("\(percent)%") }
        if showPower { parts.append(powerText) }
        title = parts.joined(separator: " · ")
        // Percentage-only mode avoids a redundant battery symbol.
        symbol = (showBattery || showPower) ? nil : "battery.50"
    }
    var titleBadgeIndex: Int? {
        switch chargingBadge {
        case .afterPercentage: return title.firstIndex(of: "%").map { title.distance(from: title.startIndex, to: $0) + 1 }
        case .afterPower: return title.count
        default: return nil
        }
    }

    func attributedTitle(font: NSFont) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color = tint.color { attributes[.foregroundColor] = color }
        let result = NSMutableAttributedString(string: title, attributes: attributes)
        if let index = titleBadgeIndex {
            let attachment = NSTextAttachment()
            attachment.image = Self.symbolImage("bolt.fill", tint: tint)
            attachment.bounds = NSRect(x: 0, y: 0, width: 6, height: 10)
            let badge = NSMutableAttributedString(string: "", attributes: attributes)
            badge.append(NSAttributedString(attachment: attachment))
            // The title already contains a separator when power follows. A
            // trailing space here needlessly widens percentage-only status items.
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

    func symbolImage() -> NSImage? {
        guard let symbol else { return nil }
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
