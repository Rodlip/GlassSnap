import AppKit
import ApplicationServices
import ScreenCaptureKit
import SnapGeometry

struct SwitcherWindow: Identifiable {
    let id = UUID()
    let window: WindowRef
    let appName: String
    let title: String
    let icon: NSImage?
    let minimized: Bool
    let canClose: Bool
    let captureID: CGWindowID?
}

/// AX work runs off the main thread: a slow app must never stall the switcher UI.
final class WindowCatalog {
    private let queue = DispatchQueue(label: "local.GlassSnap.window-actions", qos: .userInitiated)
    private let discoveryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.GlassSnap.window-catalog"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var discovery: BlockOperation?
    func cancelLoad() { discovery?.cancel(); discovery = nil }


    func load(completion: @escaping ([SwitcherWindow]) -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let descriptors = apps.map { ($0.processIdentifier, $0.localizedName ?? "Application", $0.icon) }
        cancelLoad()
        let operation = BlockOperation()
        discovery = operation
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            var order: [CGWindowID: Int] = [:]
            for (index, info) in visible.enumerated() {
                if let id = info[kCGWindowNumber as String] as? UInt32 { order[id] = index }
            }
            var result: [(SwitcherWindow, Int)] = []
            for (pid, appName, icon) in descriptors {
                guard !operation.isCancelled else { return }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.06)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { continue }
                let cgWindows = all.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }
                for element in windows {
                    guard !operation.isCancelled else { return }
                    AXUIElementSetMessagingTimeout(element, 0.06)
                    let ref = WindowRef(element: element, pid: pid)
                    let subrole = ref.attribute(kAXSubroleAttribute) as? String
                    guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole,
                          let frame = ref.frame, frame.width > 40, frame.height > 40 else { continue }
                    let title = ref.attribute(kAXTitleAttribute) as? String ?? ""
                    let minimized = ref.attribute(kAXMinimizedAttribute) as? Bool ?? false
                    // Never attach another window's screenshot on an ambiguous
                    // match. AX remains the authority for focus and close.
                    let matches = cgWindows.filter { info in
                        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                        return Geometry.approximatelyEqual(rect, frame, tolerance: 3)
                    }
                    let titled = matches.filter { !title.isEmpty && ($0[kCGWindowName as String] as? String) == title }
                    let matched = matches.count == 1 ? matches.first : (titled.count == 1 ? titled.first : nil)
                    let number = matched?[kCGWindowNumber as String] as? UInt32
                    let button = ref.attribute(kAXCloseButtonAttribute)
                    var enabled: CFTypeRef?
                    let closable: Bool
                    if let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                        AXUIElementCopyAttributeValue(button as! AXUIElement, kAXEnabledAttribute as CFString, &enabled)
                        closable = enabled as? Bool != false
                    } else { closable = false }
                    let entry = SwitcherWindow(window: ref, appName: appName, title: title.isEmpty ? appName : title,
                                               icon: icon, minimized: minimized, canClose: closable, captureID: number)
                    let rank = number.flatMap { order[$0] } ?? (pid == frontPID ? 10_000 : 20_000)
                    result.append((entry, rank))
                }
            }
            let sorted = result.sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.appName != b.0.appName { return a.0.appName.localizedStandardCompare(b.0.appName) == .orderedAscending }
                return a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
            }.map(\.0)
            DispatchQueue.main.async { if !operation.isCancelled { completion(sorted) } }
        }
        discoveryQueue.addOperation(operation)
    }

    func activate(_ entry: SwitcherWindow, close: Bool = false, completion: @escaping (Bool) -> Void) {
        // Activation is deliberately not a process-termination API.
        guard let app = NSRunningApplication(processIdentifier: entry.window.pid), !app.isTerminated else { completion(false); return }
        app.unhide()
        app.activate(options: [])
        queue.async {
            let ref = entry.window
            AXUIElementSetAttributeValue(ref.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            let raised = AXUIElementPerformAction(ref.element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(ref.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            var success = raised == .success
            if close {
                success = false
                if let button = ref.attribute(kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() {
                    // Equivalent to the red traffic-light button. Unsaved
                    // documents keep their normal save/cancel sheet.
                    success = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
                }
            }
            DispatchQueue.main.async { completion(success) }
        }
    }
}

/// One-shot, thumbnail-sized captures. No capture stream or background recording.
final class WindowThumbnails {
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
        if !permitted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    private var generation = UUID()
    private var windows: [CGWindowID: SCWindow] = [:]
    private var pending: [SwitcherWindow] = []
    private var completed = Set<UUID>()
    private var inFlight = Set<UUID>()
    private var callback: ((UUID, NSImage?) -> Void)?
    private var ready = false

    func start(update: @escaping (UUID, NSImage?) -> Void) {
        cancel()
        guard Self.permitted else { return }
        callback = update
        let token = generation
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                for window in content?.windows ?? [] { self.windows[window.windowID] = window }
                self.ready = true
                self.pump()
            }
        }
    }
    func prioritize(_ entries: [SwitcherWindow]) {
        completed.formIntersection(Set(entries.map(\.id)))
        pending = entries.filter { !completed.contains($0.id) && !inFlight.contains($0.id) }
        pump()
    }
    func cancel() {
        generation = UUID(); windows.removeAll(); pending.removeAll()
        completed.removeAll(); inFlight.removeAll(); callback = nil; ready = false
    }
    private func pump() {
        guard ready else { return }
        while inFlight.count < 2, !pending.isEmpty {
            let entry = pending.removeFirst()
            guard let number = entry.captureID, let window = windows[number], !entry.minimized else {
                completed.insert(entry.id); callback?(entry.id, nil); continue
            }
            let token = generation
            inFlight.insert(entry.id)
            let configuration = SCStreamConfiguration()
            let ratio = window.frame.width / max(1, window.frame.height)
            configuration.width = max(1, Int(min(560, 360 * ratio)))
            configuration.height = max(1, Int(min(360, 560 / ratio)))
            configuration.showsCursor = false
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.capturesAudio = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.inFlight.remove(entry.id); self.completed.insert(entry.id)
                    let thumbnail = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    self.callback?(entry.id, thumbnail)
                    self.pump()
                }
            }
        }
    }
}
