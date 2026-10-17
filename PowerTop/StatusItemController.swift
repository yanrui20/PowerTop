import AppKit
import SwiftUI

/// Menu bar extra implemented as NSStatusItem + NSPopover (system chrome, intrinsic size).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let monitor: PowerMonitor
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var detailWindow: NSWindow?
    /// Skip redundant status-item layout; rewriting length/title every 2s shifts the item.
    private var renderedPresentation: MenuBarPresentation?
    /// Accessory apps often don't resign key, so `.transient` misses outside clicks on macOS 15/26.
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var anchorObservers: [NSObjectProtocol] = []
    private var reanchorPending = false

    static func configureMenuBarSpacing() {
        // On current macOS, a fixed-length status item gets an additional 8 pt
        // on EACH side of its button. Register a process-local default before
        // AppKit creates the status bar; do not write the global preferences.
        UserDefaults.standard.register(defaults: ["NSStatusItemSpacing": 0])
    }

    var menuBarLayoutWidths: (button: CGFloat, occupied: CGFloat)? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return (button.bounds.width, window.frame.width)
    }

    init(monitor: PowerMonitor) {
        Self.configureMenuBarSpacing()
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        startObservingMonitor()
        updateStatusItem()
    }

    #if POWER_TOP_TESTING
    var testTextColor: NSColor? {
        guard let title = statusItem.button?.attributedTitle, title.length > 0 else { return nil }
        return title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    var testImageIsTemplate: Bool? { statusItem.button?.image?.isTemplate }
    func saveButtonForTest(to url: URL) throws {
        guard let button = statusItem.button,
              let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
        button.cacheDisplay(in: button.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    func showPresentationForTest(_ presentation: MenuBarPresentation) { render(presentation) }
    func showForLayoutTest() { showPopover() }
    func closeForLayoutTest() { popover.performClose(nil) }
    var layoutTestAnchor: NSRect { statusItem.button?.bounds ?? .zero }
    var layoutTestPositioningRect: NSRect { popover.positioningRect }
    var layoutTestButtonFrame: NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    var layoutTestPopoverFrame: NSRect { popover.contentViewController?.view.window?.frame ?? .zero }
    #endif

    func invalidate() {
        stopDismissMonitors()
        anchorObservers.forEach { NotificationCenter.default.removeObserver($0) }
        anchorObservers.removeAll()
        popover.performClose(nil)
        detailWindow?.delegate = nil
        detailWindow?.close()
        detailWindow = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        // Mouse-down + deferred show: a mouse-up on a transient popover is otherwise
        // treated as an outside click and the panel flashes closed immediately.
        button.sendAction(on: [.leftMouseDown])
        button.target = self
        button.action = #selector(statusItemClicked)
        button.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        anchorObservers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                   object: button, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReanchor() }
        })
        if let window = button.window {
            anchorObservers.append(center.addObserver(forName: NSWindow.didMoveNotification,
                                                       object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleReanchor() }
            })
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = StatusPopoverContent(
            monitor: monitor,
            openDetails: { [weak self] in self?.openDetails() },
            onMeasuredSize: { [weak self] size in
                self?.applyPopoverSize(size)
            }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: PopoverView.preferredWidth, height: 420)
    }

    private func startObservingMonitor() {
        observeMonitor()
    }

    private func observeMonitor() {
        withObservationTracking {
            _ = monitor.uiRefreshToken
            _ = monitor.menuBarPresentation
            _ = monitor.isDataAvailable
            _ = monitor.currentData.menuBarPowerText
            _ = monitor.currentData.effectiveIsOnAC
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeMonitor()
            }
        }
    }

    private func updateStatusItem() {
        let presentation = monitor.menuBarPresentation
        guard let button = statusItem.button else { return }
        button.toolTip = monitor.isDataAvailable
            ? "PowerTop · \(monitor.currentData.batteryPercent)% · \(monitor.currentData.menuBarPowerText)"
            : String(localized: "Built-in battery not detected. PowerTop requires a MacBook.")
        button.setAccessibilityLabel(button.toolTip)
        guard presentation != renderedPresentation else { return }
        renderedPresentation = presentation
        render(presentation)
    }

    private func render(_ presentation: MenuBarPresentation) {
        guard let button = statusItem.button else { return }
        // Explicit colors are applied to text and non-template symbols; template
        // rendering otherwise recolors everything to the menu bar's default tint.
        button.title = presentation.title
        button.attributedTitle = presentation.attributedTitle(font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
        button.image = presentation.symbolImage()
        button.imagePosition = presentation.symbol == nil ? .noImage : (presentation.title.isEmpty ? .imageOnly : .imageLeading)
        // AppKit's automatic width adds roughly 8 pt on each side. Keep 4 pt
        // per side, measuring attachments too so the charging badge isn't clipped.
        let textWidth = button.attributedTitle.size().width
        let imageWidth = button.image?.size.width ?? 0
        let gap: CGFloat = textWidth > 0 && imageWidth > 0 ? 4 : 0
        let compactWidth = max(24, ceil(textWidth + imageWidth + gap) + 8)
        if statusItem.length != compactWidth { statusItem.length = compactWidth }
        scheduleReanchor()
    }

    /// A status item moves when its title width changes; re-anchor after AppKit lays it out.
    private func scheduleReanchor() {
        guard popover.isShown, !reanchorPending else { return }
        reanchorPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reanchorPending = false
            guard self.popover.isShown, let button = self.statusItem.button else { return }
            button.window?.contentView?.layoutSubtreeIfNeeded()
            self.popover.positioningRect = button.bounds
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func statusItemClicked() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showPopover()
            }
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if let hosting = popover.contentViewController {
            let fitted = hosting.view.fittingSize
            if fitted.width > 1, fitted.height > 1 {
                applyPopoverSize(fitted)
            }
        }
        // Do not make the popover key: that emphasizes the status item text
        // and it can stick when activating a window on another display.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        monitor.isPopoverVisible = true
        startDismissMonitors()
    }

    private func startDismissMonitors() {
        stopDismissMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.dismissPopoverIfClickIsOutside()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPopoverIfClickIsOutside()
            }
        }
    }

    private func stopDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func dismissPopoverIfClickIsOutside() {
        guard popover.isShown else { return }
        let point = NSEvent.mouseLocation
        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(point) {
            return
        }
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonRect.contains(point) {
                return
            }
        }
        popover.performClose(nil)
    }

    private func applyPopoverSize(_ size: CGSize) {
        let width = max(size.width, PopoverView.preferredWidth)
        let height = max(size.height, 80)
        let next = NSSize(width: width.rounded(), height: height.rounded())
        guard abs(popover.contentSize.width - next.width) > 0.5
            || abs(popover.contentSize.height - next.height) > 0.5 else { return }
        popover.contentSize = next
        scheduleReanchor()
    }

    func openDetails() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if detailWindow == nil {
            let hosting = NSHostingController(rootView: DetailWindowView(monitor: monitor))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "PowerTop Details")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: DetailWindowView.preferredWidth, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            detailWindow = window
        }
        detailWindow?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.isPopoverVisible = false
        stopDismissMonitors()
        statusItem.button?.highlight(false)
    }
}

private struct PopoverMeasuredSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct StatusPopoverContent: View {
    let monitor: PowerMonitor
    let openDetails: () -> Void
    let onMeasuredSize: (CGSize) -> Void

    var body: some View {
        PopoverView(monitor: monitor, openDetails: openDetails)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PopoverMeasuredSizeKey.self, value: proxy.size)
                }
            }
            .onPreferenceChange(PopoverMeasuredSizeKey.self) { size in
                guard size.width > 1, size.height > 1 else { return }
                onMeasuredSize(size)
            }
    }
}
