import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let backdrop = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 202, yRadius: 202)
        NSGradient(colors: [NSColor(red: 0.09, green: 0.16, blue: 0.30, alpha: 1), NSColor(red: 0.19, green: 0.48, blue: 0.70, alpha: 1)])!.draw(in: backdrop, angle: 55)
        let glass = NSBezierPath(roundedRect: NSRect(x: 186, y: 236, width: 652, height: 552), xRadius: 62, yRadius: 62)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.30)])!.draw(in: glass, angle: 90)
        NSColor.white.withAlphaComponent(0.55).setStroke(); glass.lineWidth = 3; glass.stroke()
        for (x, width) in [(226.0, 164.0), (410.0, 204.0), (634.0, 164.0)] {
            let column = NSBezierPath(roundedRect: NSRect(x: x, y: 278, width: width, height: 468), xRadius: 24, yRadius: 24)
            NSColor.white.withAlphaComponent(x == 410 ? 0.88 : 0.30).setFill(); column.fill()
        }
        let handle = NSBezierPath(roundedRect: NSRect(x: 396, y: 445, width: 8, height: 116), xRadius: 4, yRadius: 4)
        NSColor.white.setFill(); handle.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
