import AppKit
import SwiftUI
import SnapGeometry

@main
struct GlassSnapApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let controller = SnapController()
    private let state = AppState()
    private let switcher = WindowSwitcher()
    private let updater = Updater()
    private var settingsWindow: NSWindow?
    private var previewDismiss: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var statusMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid duplicate copies monitoring the same gestures.
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.GlassSnap")
        if duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "GlassSnap")
        statusItem.button?.toolTip = "GlassSnap — arrange your space"
        let menu = NSMenu()
        menu.delegate = self
        let heading = NSMenuItem(title: "GlassSnap", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        let status = NSMenuItem(title: "Ready when you are", action: nil, keyEquivalent: "")
        statusMenuItem = status; menu.addItem(status)
        menu.addItem(.separator())
        add("Settings…", action: #selector(showSettings), key: ",", to: menu)
        add("Check for Updates…", action: #selector(checkForUpdates), to: menu)
        add("Switch windows…", action: #selector(showSwitcher), to: menu)
        add("Preview layouts", action: #selector(showPreview), to: menu)
        let layouts = NSMenuItem(title: "Arrange active window", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (i, layout) in SnapLayout.all.enumerated() {
            let item = NSMenuItem(title: layout.name, action: nil, keyEquivalent: "")
            let zones = NSMenu()
            for j in layout.zones.indices {
                let title: String
                if layout.zones.count == 1 { title = "Fill usable screen" }
                else if layout.id == "quarters" { title = ["Top left", "Top right", "Bottom left", "Bottom right"][j] }
                else if layout.id == "left-stack" { title = ["Left", "Top right", "Bottom right"][j] }
                else if layout.id == "right-stack" { title = ["Top left", "Bottom left", "Right"][j] }
                else { title = layout.zones.count == 3 ? ["Left", "Center", "Right"][j] : ["Left", "Right"][j] }
                let zone = NSMenuItem(title: title, action: #selector(arrange(_:)), keyEquivalent: "")
                zone.tag = i*10+j; zone.target = self; zones.addItem(zone)
            }
            item.submenu = zones; submenu.addItem(item)
        }
        layouts.submenu = submenu; menu.addItem(layouts)
        add("Restore active window", action: #selector(restore), to: menu)
        menu.addItem(.separator())
        let toggle = add("Pause snapping", action: #selector(toggleEnabled), to: menu)
        toggleMenuItem = toggle
        add("Quit GlassSnap", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu
        controller.onStatus = { [weak self] value in self?.state.status = value }
        controller.start()
        switcher.onStatus = { [weak self] value in self?.state.status = value }
        switcher.onOpen = { [weak self] in self?.controller.cancelInteraction() }
        switcher.start()
        updater.onStatus = { [weak self] value in self?.state.status = value }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.state.check() }
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || !Accessibility.trusted || CommandLine.arguments.contains("--settings") {
            showSettings(); UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
        if CommandLine.arguments.contains("--preview") { showPreview() }
    }
    @discardableResult private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item); return item
    }
    func menuWillOpen(_ menu: NSMenu) {
        state.check()
        statusMenuItem?.title = !state.trusted ? "Accessibility access needed" : (Preferences.shared.enabled ? "Ready to arrange" : "Snapping paused")
        toggleMenuItem?.title = Preferences.shared.enabled ? "Pause snapping" : "Resume snapping"
    }
    @objc private func showSettings() {
        state.check()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 740), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.delegate = self
            window.title = "GlassSnap"; window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(state: state, preview: { [weak self] in self?.showPreview() }, switchWindows: { [weak self] in self?.showSwitcher() }, checkForUpdates: { [weak self] in self?.checkForUpdates() }))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showSwitcher() { switcher.show() }
    @objc private func checkForUpdates() { updater.check() }
    @objc private func showPreview() {
        previewDismiss?.cancel()
        guard let screen = Screens.at(NSEvent.mouseLocation) ?? NSScreen.main else { return }
        controller.cancelInteraction()
        controller.palette.show(on: screen, demo: true)
        let work = DispatchWorkItem { [weak self] in self?.controller.palette.hide() }
        previewDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now()+6, execute: work)
    }
    @objc private func arrange(_ sender: NSMenuItem) { controller.snapFocused(layout: sender.tag/10, zone: sender.tag%10) }
    @objc private func restore() { controller.restoreFocused() }
    @objc private func toggleEnabled() { Preferences.shared.enabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { settingsWindow = nil }
    }
    func applicationWillTerminate(_ notification: Notification) { controller.stop(); switcher.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
}
