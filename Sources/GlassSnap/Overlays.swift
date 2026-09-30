import AppKit
import SnapGeometry

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(frame: CGRect, interactive: Bool = false) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        ignoresMouseEvents = !interactive
        animationBehavior = .none
    }
}

func glassContainer(content: NSView, radius: CGFloat) -> NSGlassEffectView {
    let glass = NSGlassEffectView(frame: content.frame)
    glass.style = .regular; glass.cornerRadius = radius; glass.contentView = content
    content.autoresizingMask = [.width, .height]
    return glass
}

struct ZoneChoice: Equatable {
    let layout: Int
    let zone: Int
}

final class LayoutPalette {
    private(set) var panel: OverlayPanel?
    private var view: PaletteView?
    private(set) var screenID: UInt32?
    var selection: ZoneChoice? { view?.selection }
    var isVisible: Bool { panel?.isVisible == true }

    func show(on screen: NSScreen, demo: Bool = false) {
        if screenID == Screens.id(screen), isVisible { return }
        hide()
        let width = min(650, screen.visibleFrame.width-32)
        let content = PaletteView(frame: CGRect(x: 0, y: 0, width: width, height: width < 560 ? 310 : 224))
        content.demo = demo
        let frame = CGRect(x: screen.visibleFrame.midX-width/2,
                           y: screen.visibleFrame.maxY-content.frame.height-14,
                           width: width, height: content.frame.height)
        let panel = OverlayPanel(frame: frame)
        panel.contentView = glassContainer(content: content, radius: 26)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.08
            panel.animator().alphaValue = 1
        }
        self.panel = panel; self.view = content; screenID = Screens.id(screen)
    }
    func update(at point: CGPoint) -> ZoneChoice? {
        guard let panel, let view else { return nil }
        let local = CGPoint(x: point.x-panel.frame.minX, y: panel.frame.maxY-point.y)
        view.selection = view.choice(at: local)
        return view.selection
    }
    func containsCorridor(_ point: CGPoint, screen: NSScreen) -> Bool {
        guard let panel else { return false }
        // Retain the entire path from the wider activation area into the
        // palette, with slack so small hand movements cannot flicker it away.
        let activation = Geometry.topCenterActivationArea(in: screen.frame)
        let left = min(panel.frame.minX, activation.minX)-80
        let right = max(panel.frame.maxX, activation.maxX)+80
        return CGRect(x: left, y: panel.frame.minY-100,
                      width: right-left, height: screen.frame.maxY-panel.frame.minY+100).contains(point)
    }
    func hide() { panel?.orderOut(nil); panel = nil; view = nil; screenID = nil }
}

final class PaletteView: NSView {
    override var isFlipped: Bool { true }
    var demo = false
    var selection: ZoneChoice? { didSet { if oldValue != selection { needsDisplay = true } } }
    private var columns: Int { bounds.width < 560 ? 3 : 5 }
    private var cardWidth: CGFloat { (bounds.width-40-CGFloat(columns-1)*12)/CGFloat(columns) }
    private func card(_ index: Int) -> CGRect {
        CGRect(x: 20+CGFloat(index % columns)*(cardWidth+12), y: 52+CGFloat(index/columns)*80,
               width: cardWidth, height: 52)
    }
    private func zoneRect(_ choice: ZoneChoice) -> CGRect {
        let box = card(choice.layout)
        let z = SnapLayout.all[choice.layout].zones[choice.zone]
        return CGRect(x: box.minX+z.minX*box.width+2, y: box.minY+z.minY*box.height+2,
                      width: z.width*box.width-4, height: z.height*box.height-4)
    }
    func choice(at point: CGPoint) -> ZoneChoice? {
        for (i, layout) in SnapLayout.all.enumerated() {
            for j in layout.zones.indices {
                let choice = ZoneChoice(layout: i, zone: j)
                if zoneRect(choice).insetBy(dx: -1, dy: -1).contains(point) { return choice }
            }
        }
        return nil
    }
    override func draw(_ dirtyRect: NSRect) {
        text("ARRANGE YOUR SPACE", at: CGPoint(x: 22, y: 19), size: 10, weight: .semibold, color: .secondaryLabelColor)
        text(demo ? "Layout preview" : "Drop into a zone  ·  esc to cancel", at: CGPoint(x: bounds.width-218, y: 18), size: 11, color: .secondaryLabelColor)
        for (i, layout) in SnapLayout.all.enumerated() {
            for j in layout.zones.indices {
                let choice = ZoneChoice(layout: i, zone: j)
                let rect = zoneRect(choice)
                let selected = choice == selection
                let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                (selected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
                path.fill()
                (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.18)).setStroke()
                path.lineWidth = selected ? 1.5 : 0.75; path.stroke()
                if selected {
                    let symbol = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
                    symbol?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))?.draw(in: CGRect(x: rect.midX-7, y: rect.midY-7, width: 14, height: 14))
                }
            }
            let box = card(i)
            text(layout.name, at: CGPoint(x: box.minX, y: box.maxY+7), size: 10, color: .secondaryLabelColor)
        }
    }
    private func text(_ value: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        value.draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
}

final class SnapPreview {
    private var panel: OverlayPanel?
    private var lastFrame: CGRect?
    func show(_ axRect: CGRect) {
        let frame = Screens.toCocoa(axRect)
        if lastFrame == frame { return }
        lastFrame = frame
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            let panel = OverlayPanel(frame: frame)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue-1)
            panel.hasShadow = false
            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            view.layer?.borderWidth = 2
            view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            panel.contentView = view
            panel.orderFrontRegardless()
            self.panel = panel
        }
    }
    func hide() { panel?.orderOut(nil); panel = nil; lastFrame = nil }
}

final class DividerView: NSView {
    var vertical = true
    var onDown: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onUp?() }
    override func draw(_ dirtyRect: NSRect) {
        let grip = vertical ? CGRect(x: bounds.midX-1.5, y: bounds.midY-14, width: 3, height: 28) : CGRect(x: bounds.midX-14, y: bounds.midY-1.5, width: 28, height: 3)
        NSColor.labelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class DividerOverlay {
    private(set) var panel: OverlayPanel?
    var onDown: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: (() -> Void)?
    func show(at point: CGPoint, vertical: Bool) {
        let size = vertical ? CGSize(width: 18, height: 62) : CGSize(width: 62, height: 18)
        let rect = CGRect(x: point.x-size.width/2, y: point.y-size.height/2, width: size.width, height: size.height)
        if let panel { panel.setFrame(rect, display: true); return }
        let panel = OverlayPanel(frame: rect, interactive: true)
        let view = DividerView(frame: CGRect(origin: .zero, size: size))
        view.vertical = vertical
        view.onDown = { [weak self] in self?.onDown?() }
        view.onDrag = { [weak self] p in self?.onDrag?(p) }
        view.onUp = { [weak self] in self?.onUp?() }
        panel.contentView = glassContainer(content: view, radius: 9)
        panel.orderFrontRegardless()
        self.panel = panel
    }
    func hide() { panel?.orderOut(nil); panel = nil }
}
