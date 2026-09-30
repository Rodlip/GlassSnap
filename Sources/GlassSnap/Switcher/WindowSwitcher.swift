import AppKit
import Combine
import SwiftUI
import SnapGeometry

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WindowSwitcher {
    private let catalog = WindowCatalog()
    private let thumbnails = WindowThumbnails()
    private let hotKey = SwitcherHotKey()
    private let state = SwitcherState()
    private var panel: SwitcherPanel?
    private var presentationBounds = CGRect.zero
    private var monitors: [Any] = []
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var session = UUID()
    private var holdingOption = false
    private var selection = WindowSelection()
    var onStatus: ((String) -> Void)?
    var onOpen: (() -> Void)?

    func start() {
        hotKey.pressed = { [weak self] reverse in
            guard let self else { return }
            if self.panel == nil { self.show(holdingOption: true, reverse: reverse) }
            else { self.step(reverse ? -1 : 1) }
        }
        Preferences.shared.$switcherEnabled.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            if enabled {
                if !self.hotKey.register() { self.onStatus?("Option+Tab is already in use. The window switcher is still available in the menu bar.") }
            } else { self.hotKey.unregister(); self.dismiss() }
        }.store(in: &subscriptions)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.panel != nil, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.state.windows.removeAll { $0.window.pid == app.processIdentifier }
            self.selection.updateCount(self.state.windows.count)
            self.state.selected = self.selection.index
            self.updateThumbnails()
        })
    }
    func stop() {
        dismiss(); hotKey.unregister(); subscriptions.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
    }
    func show(holdingOption: Bool = false, reverse: Bool = false) {
        guard panel == nil else { return }
        onOpen?()
        let screen = Screens.at(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        presentationBounds = screen.visibleFrame
        let availableWidth = min(1500, screen.visibleFrame.width - 64)
        let availableHeight = screen.visibleFrame.height - 80
        state.cardWidth = min(240, availableWidth - 32)
        state.cardHeight = min(182, availableHeight - 96)
        state.columns = max(1, min(5, Int((availableWidth - 32 + 12) / (state.cardWidth + 12))))
        let rows = max(1, min(2, Int((availableHeight - 96 + 12) / (state.cardHeight + 12))))
        state.pageSize = state.columns * rows
        state.windows = []; state.thumbnails = [:]; state.selected = 0
        state.loading = Accessibility.trusted
        state.hasAccessibility = Accessibility.trusted
        state.hasCaptureAccess = WindowThumbnails.permitted

        self.holdingOption = holdingOption
        selection = WindowSelection(advance: holdingOption ? (reverse ? -1 : 1) : 0)
        session = UUID()
        let token = session
        let frame = fittedFrame()
        let panel = SwitcherPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.title = "GlassSnap Window Switcher"
        let view = NSHostingView(rootView: SwitcherView(state: state,
            activate: { [weak self] in self?.activate($0) },
            close: { [weak self] in self?.activate($0, close: true) },
            permission: { [weak self] in
                let needsAX = !Accessibility.trusted
                self?.dismiss()
                if needsAX { Accessibility.requestAccess(); Accessibility.openSettings() }
                else { WindowThumbnails.requestAccess() }
            }))
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.panel = panel
        panel.alphaValue = 0
        installMonitors()
        guard state.hasAccessibility else {
            self.holdingOption = false
            presentPanel()
            return
        }
        catalog.load { [weak self] entries in
            guard let self, self.session == token, self.panel != nil else { return }
            self.state.windows = entries
            let shouldCommit = self.selection.loaded(count: entries.count)
            self.state.selected = self.selection.index
            self.state.loading = false
            if shouldCommit || (self.holdingOption && !NSEvent.modifierFlags.contains(.option)) {
                self.acceptSelection(); return
            }
            self.thumbnails.start { [weak self] id, image in
                guard let self, self.session == token,
                      self.state.pageEntries.contains(where: { $0.id == id }) else { return }
                if let image { self.state.thumbnails[id] = image }
            }
            self.updateThumbnails()
            self.presentPanel()
        }
    }
    private func step(_ amount: Int) {
        selection.move(by: amount)
        if state.loading { return }
        state.selected = selection.index
        updateThumbnails()
    }
    private func moveVertically(_ direction: Int) {
        guard !state.loading, !state.windows.isEmpty else { return }
        let columns = state.columns
        let count = state.windows.count
        let rowCount = (count + columns - 1) / columns
        let row = state.selected / columns
        let targetRow = (row + direction + rowCount) % rowCount
        let currentCount = min(columns, count - row * columns)
        let targetCount = min(columns, count - targetRow * columns)
        // Track visual X across centered rows instead of skipping a fixed
        // number of items and wrapping unexpectedly on a short final row.
        let x = CGFloat(state.selected % columns) - CGFloat(currentCount - 1) / 2
        let column = min(targetCount - 1, max(0, Int((x + CGFloat(targetCount - 1) / 2).rounded())))
        step(targetRow * columns + column - state.selected)
    }
    private func updateThumbnails() {
        fitPanel()
        let entries = state.pageEntries
        let visibleIDs = Set(entries.map(\.id))
        // Only the visible page retains images. A long window list cannot grow
        // an unbounded screenshot cache.
        state.thumbnails = state.thumbnails.filter { visibleIDs.contains($0.key) }
        let prioritized = entries.sorted { $0.id == state.selectedEntry?.id && $1.id != state.selectedEntry?.id }
        thumbnails.prioritize(prioritized)
    }
    /// The glass wraps just the current page; no reserved grid cells or header.
    private func fittedFrame() -> CGRect {
        let count = state.pageEntries.count
        let hasCards = state.hasAccessibility && !state.loading && count > 0
        let columns = min(count, state.columns)
        let rows = (count + state.columns - 1) / state.columns
        let width = hasCards ? CGFloat(columns) * state.cardWidth + CGFloat(max(0, columns - 1)) * 12 + 32 : 340
        var height = hasCards ? CGFloat(rows) * state.cardHeight + CGFloat(max(0, rows - 1)) * 12 + 32 : 156
        if !state.hasCaptureAccess || !state.hasAccessibility { height += 40 }
        if state.pageCount > 1 { height += 24 }
        return CGRect(x: presentationBounds.midX - width/2, y: presentationBounds.midY - height/2,
                      width: width, height: height)
    }
    private func fitPanel() {
        guard let panel else { return }
        let frame = fittedFrame()
        guard panel.frame != frame else { return }
        // Geometry changes are immediate. Never animate from a small loading
        // shell or interpolate the outline when changing pages.
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }
    private func presentPanel() {
        guard let panel, !panel.isVisible else { return }
        fitPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.065
            panel.animator().alphaValue = 1
        }
    }
    private func acceptSelection() {
        let canCommit = selection.requestCommit()
        if state.loading { return }
        if canCommit, let entry = state.selectedEntry { activate(entry) }
        else { holdingOption = false }
    }
    private func activate(_ entry: SwitcherWindow, close: Bool = false) {
        guard !close || entry.canClose else { NSSound.beep(); return }
        // Hide before the normal close action so save sheets remain visible
        // and no Option-release event can switch to another window afterward.
        dismiss()
        catalog.activate(entry, close: close) { [weak self] success in
            self?.onStatus?(success ? (close ? "Sent the normal close action to \(entry.appName)." : "Switched to \(entry.appName).") : "This window is no longer available or the app refused the action.")
        }
    }
    func dismiss() {
        session = UUID(); holdingOption = false; selection = WindowSelection()
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        catalog.cancelLoad()
        thumbnails.cancel()
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
        state.windows = []; state.thumbnails = [:]
    }
    private func installMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .flagsChanged { self.modifiersChanged(event.modifierFlags); return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== panel { self.dismiss() }
                return event
            }
            switch event.keyCode {
            case 53: self.dismiss()
            case 36, 76: self.acceptSelection()
            case 48: self.step(event.modifierFlags.contains(.shift) ? -1 : 1)
            case 123: self.step(-1)
            case 124: self.step(1)
            case 125: self.moveVertically(1)
            case 126: self.moveVertically(-1)
            case 13 where event.modifierFlags.contains(.command):
                if let entry = self.state.selectedEntry { self.activate(entry, close: true) }
            default: return event
            }
            return nil
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if event.type == .flagsChanged { self?.modifiersChanged(event.modifierFlags) }
            else { self?.dismiss() }
        }) { monitors.append(global) }
    }
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        if holdingOption && !flags.contains(.option) { holdingOption = false; acceptSelection() }
    }
}
