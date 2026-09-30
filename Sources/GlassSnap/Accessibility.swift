import AppKit
import ApplicationServices
import SnapGeometry

struct WindowRef: Equatable {
    let element: AXUIElement
    let pid: pid_t

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }

    var frame: CGRect? {
        guard let p: CGPoint = axValue(kAXPositionAttribute, type: .cgPoint),
              let s: CGSize = axValue(kAXSizeAttribute, type: .cgSize) else { return nil }
        return CGRect(origin: p, size: s)
    }
    var minimumSize: CGSize {
        let size: CGSize? = axValue("AXMinSize", type: .cgSize)
        return size ?? CGSize(width: 240, height: 160)
    }
    var isUsable: Bool {
        guard NSRunningApplication(processIdentifier: pid)?.isHidden == false,
              (attribute(kAXMinimizedAttribute) as? Bool) != true,
              (attribute("AXFullScreen") as? Bool) != true else { return false }
        return frame != nil
    }
    func attribute(_ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    private func axValue<T>(_ key: String, type: AXValueType) -> T? {
        guard let value = attribute(key), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        guard AXValueGetValue(value as! AXValue, type, buffer) else { return nil }
        return buffer.pointee
    }
    @discardableResult func setFrame(_ rect: CGRect) -> Bool {
        var point = rect.origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        // Shrink first, move, then grow: cross-display moves can otherwise be
        // constrained by the old display's bounds.
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
        let positionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
        return sizeResult == .success && positionResult == .success
    }
}

enum Accessibility {
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    static func window(at cocoaPoint: CGPoint) -> WindowRef? {
        guard trusted else { return nil }
        let point = Screens.toAX(cocoaPoint)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              var current = element else { return nil }
        for _ in 0..<12 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXWindowRole { return validated(current) }
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                return validated(window as! AXUIElement)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }
    static func focusedWindow() -> WindowRef? {
        guard trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.08)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return validated(window as! AXUIElement)
    }
    private static func validated(_ element: AXUIElement) -> WindowRef? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.08)
        let window = WindowRef(element: element, pid: pid)
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        guard positionSettable.boolValue, sizeSettable.boolValue, window.isUsable else { return nil }
        return window
    }
}

enum Screens {
    static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    static func toAX(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryTop-p.y) }
    static func toAX(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryTop-r.maxY, width: r.width, height: r.height) }
    static func toCocoa(_ r: CGRect) -> CGRect { toAX(r) }
    static func at(_ point: CGPoint) -> NSScreen? { NSScreen.screens.first { $0.frame.contains(point) } }
    static func id(_ screen: NSScreen) -> UInt32 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    static func withID(_ id: UInt32) -> NSScreen? { NSScreen.screens.first { self.id($0) == id } }
}

final class WindowAnimator {
    private var timer: Timer?
    private var completion: (() -> Void)?
    func cancel() { timer?.invalidate(); timer = nil; completion = nil }
    func move(_ window: WindowRef, to target: CGRect, animated: Bool, completion: @escaping () -> Void) {
        cancel()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let start = window.frame else {
            window.setFrame(target); completion(); return
        }
        let began = ProcessInfo.processInfo.systemUptime
        self.completion = completion
        let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] timer in
            let t = min(1, (ProcessInfo.processInfo.systemUptime-began)/0.18)
            let eased = CGFloat(1-pow(1-t, 3))
            let rect = CGRect(x: start.minX+(target.minX-start.minX)*eased,
                              y: start.minY+(target.minY-start.minY)*eased,
                              width: start.width+(target.width-start.width)*eased,
                              height: start.height+(target.height-start.height)*eased)
            if !window.setFrame(rect) || t >= 1 {
                timer.invalidate(); self?.timer = nil
                let done = self?.completion; self?.completion = nil; done?()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
