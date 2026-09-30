import Foundation
import CoreGraphics

public struct SnapLayout: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Unit coordinates, with the origin at the top left.
    public let zones: [CGRect]

    public init(id: String, name: String, zones: [CGRect]) {
        self.id = id; self.name = name; self.zones = zones
    }

    public static let all: [SnapLayout] = [
        .init(id: "halves", name: "Equal halves", zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]),
        .init(id: "wide-left", name: "Wide left", zones: [
            CGRect(x: 0, y: 0, width: 2.0/3, height: 1), CGRect(x: 2.0/3, y: 0, width: 1.0/3, height: 1)]),
        .init(id: "wide-right", name: "Wide right", zones: [
            CGRect(x: 0, y: 0, width: 1.0/3, height: 1), CGRect(x: 1.0/3, y: 0, width: 2.0/3, height: 1)]),
        .init(id: "thirds", name: "Three columns", zones: (0..<3).map {
            CGRect(x: Double($0)/3, y: 0, width: 1.0/3, height: 1) }),
        .init(id: "focus", name: "Focus center", zones: [
            CGRect(x: 0, y: 0, width: 0.25, height: 1), CGRect(x: 0.25, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.75, y: 0, width: 0.25, height: 1)]),
        .init(id: "left-stack", name: "Left & stack", zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]),
        .init(id: "right-stack", name: "Stack & right", zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]),
        .init(id: "quarters", name: "Four quarters", zones: (0..<4).map {
            CGRect(x: Double($0 % 2)/2, y: Double($0 / 2)/2, width: 0.5, height: 0.5) }),
        .init(id: "full", name: "Maximize", zones: [CGRect(x: 0, y: 0, width: 1, height: 1)])
    ]
}

public enum Geometry {
    /// A generous top-center target in Cocoa screen coordinates. Keep it wide
    /// on ultrawides and deep enough to enter without touching the menu bar.
    public static func topCenterActivationArea(in screen: CGRect) -> CGRect {
        let width = min(screen.width, max(800, screen.width * 0.6))
        let depth = min(screen.height, min(140, max(100, screen.height * 0.12)))
        return CGRect(x: screen.midX-width/2, y: screen.maxY-depth, width: width, height: depth)
    }

    /// All calculations use display points, never physical pixels. Rounding edges
    /// independently keeps adjacent zones aligned at every backing scale.
    public static func frame(_ zone: CGRect, in screen: CGRect, gap: CGFloat, scale: CGFloat = 1) -> CGRect {
        let s = max(1, scale)
        func roundEdge(_ value: CGFloat) -> CGFloat { (value * s).rounded() / s }
        let usable = screen.insetBy(dx: gap, dy: gap)
        let left = roundEdge(usable.minX + zone.minX * usable.width + (zone.minX > 0.001 ? gap/2 : 0))
        let right = roundEdge(usable.minX + zone.maxX * usable.width - (zone.maxX < 0.999 ? gap/2 : 0))
        let top = roundEdge(usable.minY + zone.minY * usable.height + (zone.minY > 0.001 ? gap/2 : 0))
        let bottom = roundEdge(usable.minY + zone.maxY * usable.height - (zone.maxY < 0.999 ? gap/2 : 0))
        return CGRect(x: left, y: top, width: max(1, right-left), height: max(1, bottom-top))
    }

    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance &&
        abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
    }

    /// Changes a shared line, including every zone touching it (e.g. all four
    /// windows in a grid). Minimum fractions may be supplied per zone.
    public static func resized(_ zones: [CGRect], vertical: Bool, boundary: CGFloat,
                               to requested: CGFloat, minimums: [CGFloat]) -> [CGRect]? {
        let epsilon: CGFloat = 0.001
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        var touched = false
        for (i, z) in zones.enumerated() {
            let start = vertical ? z.minX : z.minY
            let end = vertical ? z.maxX : z.maxY
            let minimum = i < minimums.count ? minimums[i] : 0.1
            if abs(end-boundary) < epsilon { lower = max(lower, start+minimum); touched = true }
            if abs(start-boundary) < epsilon { upper = min(upper, end-minimum); touched = true }
        }
        guard touched, lower <= upper else { return nil }
        let value = min(upper, max(lower, requested))
        return zones.map { z in
            var result = z
            let start = vertical ? z.minX : z.minY
            let end = vertical ? z.maxX : z.maxY
            if abs(end-boundary) < epsilon {
                if vertical { result.size.width = value-start } else { result.size.height = value-start }
            }
            if abs(start-boundary) < epsilon {
                if vertical { result.origin.x = value; result.size.width = end-value }
                else { result.origin.y = value; result.size.height = end-value }
            }
            return result
        }
    }
}
