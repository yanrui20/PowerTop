import AppKit
import SwiftUI

/// Menu bar extra implemented as NSStatusItem + NSPopover (system chrome, intrinsic size).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let monitor: PowerMonitor
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var detailWindow: NSWindow?
    private var startupWindow: NSWindow?
    private var layoutWindow: NSWindow?
    private let startupController = StartupItemsController()
    private var appearanceObservation: NSKeyValueObservation?
    /// Skip redundant status-item layout; rewriting length/title every 2s shifts the item.
    private var renderedPresentation: MenuBarPresentation?
    private var renderedNormalColor: NSColor?
    private var appearanceUpdatePending = false
    private var renderedAccessibilityLabel: String?
    #if POWER_TOP_TESTING
    private(set) var testRenderCount = 0
    func testAppearanceNotification() { scheduleAppearanceUpdate() }
    func testSetAppearance(_ name: NSAppearance.Name?) {
        statusItem.button?.appearance = name.flatMap(NSAppearance.init(named:))
        scheduleAppearanceUpdate()
    }
    #endif
    /// Accessory apps often don't resign key, so `.transient` misses outside clicks on macOS 15/26.
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var anchorObservers: [NSObjectProtocol] = []
    private var reanchorPending = false
    private var wantsPopoverVisible = false
    private var visibilityRevision = 0
    private var invalidated = false

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
    var testToolTip: String? { statusItem.button?.toolTip }
    func closeDetailsForTest() { detailWindow?.performClose(nil) }
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
    func closeForLayoutTest() { closePopover() }
    func clickForTest() { statusItemClicked() }
    func outsideClickForTest() { dismissPopoverIfClickIsOutside(at: NSPoint(x: -100_000, y: -100_000)) }
    func externalClickForTest() {
        let frame = popover.contentViewController?.view.window?.frame ?? .zero
        dismissPopoverForExternalAppClick(at: NSPoint(x: frame.midX, y: frame.midY))
    }
    var testPopoverVisible: Bool { popover.isShown }
    var testDismissMonitorsActive: Bool { localClickMonitor != nil && globalClickMonitor != nil }
    var layoutTestAnchor: NSRect { statusItem.button?.bounds ?? .zero }
    var layoutTestPositioningRect: NSRect { popover.positioningRect }
    var layoutTestButtonFrame: NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    var layoutTestPopoverFrame: NSRect { popover.contentViewController?.view.window?.frame ?? .zero }
    #endif

    func invalidate() {
        invalidated = true
        closePopover()
        anchorObservers.forEach { NotificationCenter.default.removeObserver($0) }
        anchorObservers.removeAll()
        monitor.isBatteryDetailsVisible = false
        detailWindow?.delegate = nil
        detailWindow?.close()
        detailWindow = nil
        for window in [startupWindow, layoutWindow] { window?.delegate = nil; window?.close() }
        startupWindow = nil; layoutWindow = nil
        appearanceObservation?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.target = self
        button.action = #selector(statusItemClicked)
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // Multi-display status-item snapshots can temporarily change appearance
            // while drawing. Defer to the stable appearance and deduplicate the result.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.scheduleAppearanceUpdate() }
            } else {
                Task { @MainActor in self?.scheduleAppearanceUpdate() }
            }
        }
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
        // One owner handles dismissal. A transient popover can close BEFORE the
        // status-button action runs, causing that same click to open it again.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let root = StatusPopoverContent(
            monitor: monitor,
            openDetails: { [weak self] in self?.openDetails() },
            openStartupItems: { [weak self] in self?.openStartupItems() },
            openMenuBarLayout: { [weak self] in self?.openMenuBarLayout() },
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
        guard !invalidated else { return }
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

    private func scheduleAppearanceUpdate() {
        guard !invalidated, !appearanceUpdatePending else { return }
        appearanceUpdatePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appearanceUpdatePending = false
            guard !self.invalidated else { return }
            self.render(self.renderedPresentation ?? self.monitor.menuBarPresentation)
        }
    }

    private func updateStatusItem() {
        guard !invalidated else { return }
        let presentation = monitor.menuBarPresentation
        guard let button = statusItem.button else { return }
        if button.toolTip != nil { button.toolTip = nil }
        let accessibilityLabel = monitor.menuBarToolTip
        if accessibilityLabel != renderedAccessibilityLabel {
            renderedAccessibilityLabel = accessibilityLabel
            button.setAccessibilityLabel(accessibilityLabel)
        }
        render(presentation)
    }

    private func render(_ presentation: MenuBarPresentation) {
        guard let button = statusItem.button else { return }
        var normalColor = NSColor.labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            normalColor = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
        }
        guard presentation != renderedPresentation || renderedNormalColor?.isEqual(normalColor) != true else { return }
        // Set the cache before AppKit mutations, which can produce appearance notifications.
        renderedPresentation = presentation
        renderedNormalColor = normalColor
        #if POWER_TOP_TESTING
        testRenderCount += 1
        #endif
        // Explicit colors are applied to text and non-template symbols; template
        // rendering otherwise recolors everything to the menu bar's default tint.
        if !presentation.needsCompositeImage {
            button.title = presentation.title
            button.attributedTitle = presentation.attributedTitle(font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
            button.image = presentation.symbolImage()
            button.imagePosition = presentation.symbol == nil ? .noImage : (presentation.title.isEmpty ? .imageOnly : .imageLeading)
        } else {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = presentation.compactStatusImage(normalColor: normalColor)
            button.imagePosition = .imageOnly
        }
        // Keep only 2 pt per side while retaining a usable minimum hit area.
        // Measure attachments too so the charging badge isn't clipped.
        let textWidth = button.attributedTitle.size().width
        let imageWidth = button.image?.size.width ?? 0
        let gap: CGFloat = textWidth > 0 && imageWidth > 0 ? 4 : 0
        let compactWidth = max(24, ceil(textWidth + imageWidth + gap) + 4)
        if statusItem.length != compactWidth { statusItem.length = compactWidth }
        scheduleReanchor()
    }

    /// A status item moves when its title width changes; re-anchor after AppKit lays it out.
    private func scheduleReanchor() {
        guard wantsPopoverVisible, popover.isShown, !reanchorPending, !invalidated else { return }
        reanchorPending = true
        let revision = visibilityRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibilityRevision == revision, !self.invalidated else { return }
            self.reanchorPending = false
            guard self.wantsPopoverVisible, self.popover.isShown, let button = self.statusItem.button else { return }
            button.window?.contentView?.layoutSubtreeIfNeeded()
            // Updating positioningRect repositions an already-visible popover.
            // Calling show() again can emit close callbacks and lose monitors.
            self.popover.positioningRect = button.bounds
        }
    }

    @objc private func statusItemClicked() {
        guard !invalidated else { return }
        if wantsPopoverVisible || popover.isShown {
            closePopover()
        } else {
            wantsPopoverVisible = true
            visibilityRevision &+= 1
            let revision = visibilityRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsPopoverVisible, self.visibilityRevision == revision,
                      !self.invalidated else { return }
                self.showPopover()
            }
        }
    }

    private func closePopover() {
        wantsPopoverVisible = false
        visibilityRevision &+= 1
        reanchorPending = false
        monitor.isPopoverVisible = false
        stopDismissMonitors()
        popover.close()
        statusItem.button?.highlight(false)
    }

    private func showPopover() {
        guard !invalidated else { return }
        wantsPopoverVisible = true
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
            // Picker/context-menu windows belong to the popover interaction.
            if event.window?.level == .popUpMenu { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            Task { @MainActor in self?.dismissPopoverIfClickIsOutside(at: point) }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissPopoverForExternalAppClick(at: point) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                Task { @MainActor in self?.closePopover() }
            }
    }

    private func stopDismissMonitors() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func dismissPopoverForExternalAppClick(at point: NSPoint) {
        guard wantsPopoverVisible || popover.isShown else { return }
        if let button = statusItem.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
        // Global events come from another app. Do not classify an overlapping
        // window as "inside" merely because its click shares popover coordinates.
        closePopover()
    }

    private func dismissPopoverIfClickIsOutside(at point: NSPoint) {
        guard wantsPopoverVisible || popover.isShown else { return }
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
        closePopover()
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

    func openStartupItems() {
        closePopover()
        if startupWindow == nil {
            let hosting = NSHostingController(rootView: StartupItemsView(controller: startupController,
                onChange: { [weak monitor] in monitor?.refreshLaunchAtLoginStatus() }))
            startupWindow = makeToolWindow(hosting, title: String(localized: "Startup Item Manager"), size: NSSize(width: 850, height: 620))
        }
        NSApp.activate(ignoringOtherApps: true)
        startupWindow?.makeKeyAndOrderFront(nil)
        Task { await startupController.refresh(); monitor.refreshLaunchAtLoginStatus() }
    }
    func openMenuBarLayout() {
        closePopover()
        if layoutWindow == nil {
            layoutWindow = makeToolWindow(NSHostingController(rootView: MenuBarLayoutView(monitor: monitor)),
                title: String(localized: "Menu Bar Layout"), size: NSSize(width: 560, height: 500))
        }
        NSApp.activate(ignoringOtherApps: true)
        layoutWindow?.makeKeyAndOrderFront(nil)
    }
    private func makeToolWindow(_ content: NSViewController, title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentViewController: content)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.minSize = size
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func openDetails() {
        closePopover()
        monitor.isBatteryDetailsVisible = true
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
        if sender === detailWindow { monitor.isBatteryDetailsVisible = false }
        sender.orderOut(nil)
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === detailWindow {
            monitor.isBatteryDetailsVisible = false
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === detailWindow {
            monitor.isBatteryDetailsVisible = true
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        wantsPopoverVisible = false
        visibilityRevision &+= 1
        reanchorPending = false
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
    let openStartupItems: () -> Void
    let openMenuBarLayout: () -> Void
    let onMeasuredSize: (CGSize) -> Void

    var body: some View {
        PopoverView(monitor: monitor, openDetails: openDetails, openStartupItems: openStartupItems, openMenuBarLayout: openMenuBarLayout)
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
