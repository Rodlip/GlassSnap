import AppKit
import SnapGeometry

private struct Placement {
    let window: WindowRef
    var expected: CGRect
}
private final class SnapGroup {
    let id = UUID()
    let screenID: UInt32
    let layoutID: String
    var zones: [CGRect]
    var windows: [Int: Placement] = [:]
    init(screenID: UInt32, layout: SnapLayout) {
        self.screenID = screenID; layoutID = layout.id; zones = layout.zones
    }
}
private struct Seam {
    let groupID: UUID
    let vertical: Bool
    let boundary: CGFloat
    let lower: CGFloat
    let upper: CGFloat
    let first: Int
    let second: Int
}

final class SnapController {
    let palette = LayoutPalette()
    private let preview = SnapPreview()
    private let divider = DividerOverlay()
    private let animator = WindowAnimator()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var candidate: WindowRef?
    private var initialFrame: CGRect?
    private var mouseDownPoint = CGPoint.zero
    private var draggingWindow = false
    private var edgeEntered: TimeInterval?
    private var edgeWork: DispatchWorkItem?
    private var groups: [SnapGroup] = []
    private var originals: [(WindowRef, CGRect)] = []
    private var currentSeam: Seam?
    private var resizing = false
    private var resizeZones: [CGRect] = []
    private var resizeOriginals: [Int: CGRect] = [:]
    private var minimums: [CGFloat] = []
    private var lastEventTime: TimeInterval = 0
    private var lastValidationTime: TimeInterval = 0
    private let preferences = Preferences.shared
    var onStatus: ((String) -> Void)?

    func start() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown], handler: { [weak self] event in
            self?.handle(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown], handler: { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.cancelInteraction() }
            if event.type == .mouseMoved { self?.hoverDivider(at: NSEvent.mouseLocation) }
            return event
        }) { monitors.append(monitor) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetGroups()
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.divider.hide(); self?.currentSeam = nil
                if name == NSWorkspace.activeSpaceDidChangeNotification { self?.cancelInteraction() }
            })
        }
        divider.onDown = { [weak self] in self?.beginResize() }
        divider.onDrag = { [weak self] point in self?.resize(at: point) }
        divider.onUp = { [weak self] in self?.finishResize() }
        preferences.changed = { [weak self] in self?.resetGroups() }
    }
    func stop() {
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll(); cancelInteraction(); animator.cancel()
    }
    private func resetGroups() { cancelInteraction(); animator.cancel(); groups.removeAll() }
    private func handle(_ event: NSEvent) {
        guard preferences.enabled else { return }
        if event.type == .mouseMoved { hoverDivider(at: NSEvent.mouseLocation); return }
        guard Accessibility.trusted else { return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { cancelInteraction() }
        case .leftMouseDown:
            animator.cancel(); palette.hide(); preview.hide(); divider.hide()
            currentSeam = nil; edgeEntered = nil; edgeWork?.cancel(); edgeWork = nil
            candidate = Accessibility.window(at: point)
            initialFrame = candidate?.frame; mouseDownPoint = point; draggingWindow = false
        case .leftMouseDragged:
            guard !resizing else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now-lastEventTime >= 1.0/60 else { return }
            lastEventTime = now
            updateDrag(at: point)
        case .leftMouseUp:
            guard !resizing else { return }
            edgeWork?.cancel(); edgeWork = nil
            // Use the release location, rather than the last throttled drag event.
            if palette.isVisible { _ = palette.update(at: point) }
            if let window = candidate, draggingWindow, let selection = palette.selection,
               let screenID = palette.screenID, let screen = Screens.withID(screenID) {
                snap(window, choice: selection, on: screen)
            }
            candidate = nil; initialFrame = nil; draggingWindow = false; edgeEntered = nil
            palette.hide(); preview.hide()
        case .mouseMoved: hoverDivider(at: point)
        default: break
        }
    }
    private func updateDrag(at point: CGPoint) {
        guard let window = candidate, let initialFrame, let screen = Screens.at(point) else { return }
        if !draggingWindow {
            guard hypot(point.x-mouseDownPoint.x, point.y-mouseDownPoint.y) > 6,
                  let current = window.frame,
                  hypot(current.minX-initialFrame.minX, current.minY-initialFrame.minY) > 3,
                  abs(current.width-initialFrame.width) < 3, abs(current.height-initialFrame.height) < 3 else { return }
            draggingWindow = true
            // A real move detaches the window from its previous shared divider.
            removeFromGroups(window)
        }
        if palette.isVisible {
            if palette.screenID != Screens.id(screen) || !palette.containsCorridor(point, screen: screen) {
                palette.hide(); preview.hide(); edgeEntered = nil
            } else {
                if let choice = palette.update(at: point) { preview.show(target(choice, on: screen)) }
                else { preview.hide() }
                return
            }
        }
        if Geometry.topCenterActivationArea(in: screen.frame).contains(point) {
            // The center is the primary gesture: no dwell and no need to hit
            // the physical edge. Cancel any pending outer-edge activation.
            edgeWork?.cancel(); edgeWork = nil; edgeEntered = nil
            palette.show(on: screen)
            if let choice = palette.update(at: point) { preview.show(target(choice, on: screen)) }
        } else if point.y >= screen.frame.maxY-10 {
            if edgeEntered == nil {
                edgeEntered = ProcessInfo.processInfo.systemUptime
                // One cancellable delay only during an edge gesture; no idle timer.
                let screenID = Screens.id(screen)
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.draggingWindow, self.candidate != nil,
                          NSEvent.pressedMouseButtons & 1 != 0,
                          let screen = Screens.withID(screenID),
                          Screens.at(NSEvent.mouseLocation).map(Screens.id) == screenID,
                          NSEvent.mouseLocation.y >= screen.frame.maxY-14 else { return }
                    self.palette.show(on: screen)
                }
                edgeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now()+preferences.edgeDelay, execute: work)
            }
        } else { edgeEntered = nil; edgeWork?.cancel(); edgeWork = nil }
    }
    private func matchingGroup(_ choice: ZoneChoice, screen: NSScreen) -> SnapGroup? {
        groups.last { $0.screenID == Screens.id(screen) && $0.layoutID == SnapLayout.all[choice.layout].id }
    }
    private func target(_ choice: ZoneChoice, on screen: NSScreen) -> CGRect {
        let zones = matchingGroup(choice, screen: screen)?.zones ?? SnapLayout.all[choice.layout].zones
        return frame(zones[choice.zone], on: screen)
    }
    private func frame(_ zone: CGRect, on screen: NSScreen) -> CGRect {
        Geometry.frame(zone, in: Screens.toAX(screen.visibleFrame), gap: preferences.gap, scale: screen.backingScaleFactor)
    }
    func snapFocused(layout: Int, zone: Int) {
        guard let window = Accessibility.focusedWindow(), let rect = window.frame else {
            onStatus?("Select a resizable app window first."); return
        }
        let center = Screens.toCocoa(rect)
        let screen = Screens.at(CGPoint(x: center.midX, y: center.midY)) ?? NSScreen.main
        if let screen { snap(window, choice: ZoneChoice(layout: layout, zone: zone), on: screen) }
    }
    private func snap(_ window: WindowRef, choice: ZoneChoice, on screen: NSScreen) {
        guard let original = window.frame else { return }
        if !originals.contains(where: { $0.0 == window }) {
            originals.append((window, initialFrame ?? original))
            if originals.count > 64 { originals.removeFirst() }
        }
        let group = matchingGroup(choice, screen: screen) ?? SnapGroup(screenID: Screens.id(screen), layout: SnapLayout.all[choice.layout])
        if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
        let destination = frame(group.zones[choice.zone], on: screen)
        removeFromGroups(window, keeping: group.id)
        group.windows = group.windows.filter { $0.value.window != window }
        animator.move(window, to: destination, animated: preferences.animate) { [weak self, weak group] in
            guard let self, let group else { return }
            // Native app minimum sizes can be larger than advertised. Never
            // create a shared divider for a window that did not fit its zone.
            if let actual = window.frame, Geometry.approximatelyEqual(actual, destination) {
                group.windows[choice.zone] = Placement(window: window, expected: actual)
                self.onStatus?("Arranged in \(SnapLayout.all[choice.layout].name.lowercased()).")
            } else { self.onStatus?("This app could not fit the selected zone. Try a wider layout.") }
        }
        if groups.count > 24 { groups.removeFirst(groups.count-24) }
    }
    func restoreFocused() {
        guard let window = Accessibility.focusedWindow(), let index = originals.firstIndex(where: { $0.0 == window }) else {
            onStatus?("No saved size for the selected window."); return
        }
        let saved = originals.remove(at: index).1
        removeFromGroups(window)
        animator.move(window, to: saved, animated: preferences.animate) {}
    }
    private func removeFromGroups(_ window: WindowRef, keeping: UUID? = nil) {
        for group in groups { group.windows = group.windows.filter { $0.value.window != window } }
        groups.removeAll { $0.windows.isEmpty && $0.id != keeping }
    }
    func cancelInteraction() {
        edgeWork?.cancel(); edgeWork = nil
        if resizing, let seam = currentSeam, let group = groups.first(where: { $0.id == seam.groupID }) {
            for (i, rect) in resizeOriginals { group.windows[i]?.window.setFrame(rect); group.windows[i]?.expected = rect }
            group.zones = resizeZones
        }
        resizing = false; resizeOriginals = [:]; resizeZones = []
        candidate = nil; initialFrame = nil; draggingWindow = false; edgeEntered = nil
        palette.hide(); preview.hide(); divider.hide(); currentSeam = nil
    }
    private func seams(in group: SnapGroup) -> [Seam] {
        let occupied = group.windows.keys.sorted()
        var result: [Seam] = []
        for a in occupied {
            for b in occupied where a != b {
                let first = group.zones[a], second = group.zones[b]
                if abs(first.maxX-second.minX) < 0.001, min(first.maxY, second.maxY)-max(first.minY, second.minY) > 0.01 {
                    result.append(Seam(groupID: group.id, vertical: true, boundary: first.maxX,
                                       lower: max(first.minY, second.minY), upper: min(first.maxY, second.maxY), first: a, second: b))
                }
                if abs(first.maxY-second.minY) < 0.001, min(first.maxX, second.maxX)-max(first.minX, second.minX) > 0.01 {
                    result.append(Seam(groupID: group.id, vertical: false, boundary: first.maxY,
                                       lower: max(first.minX, second.minX), upper: min(first.maxX, second.maxX), first: a, second: b))
                }
            }
        }
        return result
    }
    private func hoverDivider(at point: CGPoint) {
        guard !resizing, !draggingWindow, candidate == nil, !palette.isVisible,
              preferences.enabled, preferences.dividers, !groups.isEmpty else { return }
        if let panel = divider.panel, panel.frame.insetBy(dx: -10, dy: -10).contains(point) { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now-lastEventTime > 1.0/30 else { return }
        lastEventTime = now
        let ax = Screens.toAX(point)
        for group in groups.reversed() {
            guard let screen = Screens.withID(group.screenID) else { continue }
            let usable = Screens.toAX(screen.visibleFrame).insetBy(dx: preferences.gap, dy: preferences.gap)
            for seam in seams(in: group) {
                let line = seam.vertical ? usable.minX+seam.boundary*usable.width : usable.minY+seam.boundary*usable.height
                let along = seam.vertical ? (ax.y-usable.minY)/usable.height : (ax.x-usable.minX)/usable.width
                guard abs((seam.vertical ? ax.x : ax.y)-line) <= max(12, preferences.gap/2+5), along > seam.lower+0.02, along < seam.upper-0.02 else { continue }
                guard now-lastValidationTime > 0.12 else { return }
                lastValidationTime = now
                guard validate(group), exposed(seam, group: group, at: ax) else { continue }
                if currentSeam?.vertical != seam.vertical { divider.hide() }
                currentSeam = seam
                let center = seam.vertical ? CGPoint(x: line, y: ax.y) : CGPoint(x: ax.x, y: line)
                divider.show(at: Screens.toAX(center), vertical: seam.vertical)
                return
            }
        }
        divider.hide(); currentSeam = nil
    }
    private func validate(_ group: SnapGroup) -> Bool {
        let invalid = group.windows.compactMap { index, placement -> Int? in
            guard placement.window.isUsable, let actual = placement.window.frame,
                  Geometry.approximatelyEqual(actual, placement.expected) else { return index }
            return nil
        }
        for index in invalid { group.windows.removeValue(forKey: index) }
        return group.windows.count >= 2
    }
    private func exposed(_ seam: Seam, group: SnapGroup, at point: CGPoint) -> Bool {
        guard let first = group.windows[seam.first], let second = group.windows[seam.second],
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        func topWindow(matches placement: Placement, sample: CGPoint) -> Bool {
            for info in list {
                guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                      pid != Int(ProcessInfo.processInfo.processIdentifier),
                      let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dictionary), rect.contains(sample) else { continue }
                return pid == Int(placement.window.pid) && Geometry.approximatelyEqual(rect, placement.expected, tolerance: 8)
            }
            return false
        }
        let a = seam.vertical ? CGPoint(x: first.expected.maxX-20, y: point.y) : CGPoint(x: point.x, y: first.expected.maxY-20)
        let b = seam.vertical ? CGPoint(x: second.expected.minX+20, y: point.y) : CGPoint(x: point.x, y: second.expected.minY+20)
        return topWindow(matches: first, sample: a) && topWindow(matches: second, sample: b)
    }
    private func beginResize() {
        guard let seam = currentSeam, let group = groups.first(where: { $0.id == seam.groupID }),
              let screen = Screens.withID(group.screenID), validate(group),
              exposed(seam, group: group, at: Screens.toAX(NSEvent.mouseLocation)) else { divider.hide(); return }
        animator.cancel(); resizing = true
        resizeZones = group.zones
        resizeOriginals = group.windows.mapValues(\.expected)
        let usable = screen.visibleFrame.insetBy(dx: preferences.gap, dy: preferences.gap)
        minimums = group.zones.indices.map { index in
            let minimum = group.windows[index]?.window.minimumSize ?? CGSize(width: 180, height: 120)
            return seam.vertical ? (minimum.width+preferences.gap)/usable.width : (minimum.height+preferences.gap)/usable.height
        }
    }
    private func resize(at point: CGPoint, force: Bool = false) {
        guard resizing, let seam = currentSeam, let group = groups.first(where: { $0.id == seam.groupID }),
              let screen = Screens.withID(group.screenID) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now-lastEventTime >= 1.0/60 else { return }
        lastEventTime = now
        let usable = Screens.toAX(screen.visibleFrame).insetBy(dx: preferences.gap, dy: preferences.gap)
        let ax = Screens.toAX(point)
        let desired = seam.vertical ? (ax.x-usable.minX)/usable.width : (ax.y-usable.minY)/usable.height
        guard let zones = Geometry.resized(resizeZones, vertical: seam.vertical, boundary: seam.boundary, to: desired, minimums: minimums) else { return }
        let previous = group.windows.mapValues(\.expected)
        var failed = false
        // Apply all windows sharing this line, then verify app-imposed constraints.
        for (i, placement) in group.windows {
            let destination = frame(zones[i], on: screen)
            if !Geometry.approximatelyEqual(placement.expected, destination, tolerance: 0.5) {
                if !placement.window.setFrame(destination) { failed = true }
            }
        }
        for (i, placement) in group.windows {
            let destination = frame(zones[i], on: screen)
            if let actual = placement.window.frame, Geometry.approximatelyEqual(actual, destination) {
                group.windows[i]?.expected = actual
            } else { failed = true }
        }
        if failed {
            for (i, rect) in previous { group.windows[i]?.window.setFrame(rect); group.windows[i]?.expected = rect }
            onStatus?("An app reached its minimum window size.")
            return
        }
        group.zones = zones
        let z = zones[seam.first]
        let line = seam.vertical ? usable.minX+z.maxX*usable.width : usable.minY+z.maxY*usable.height
        let center = seam.vertical ? CGPoint(x: line, y: ax.y) : CGPoint(x: ax.x, y: line)
        divider.show(at: Screens.toAX(center), vertical: seam.vertical)
    }
    private func finishResize() {
        guard resizing else { return }
        resize(at: NSEvent.mouseLocation, force: true)
        resizing = false; resizeOriginals = [:]; resizeZones = []
        divider.hide(); currentSeam = nil
    }
}
