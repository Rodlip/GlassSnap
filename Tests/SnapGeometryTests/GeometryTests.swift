import XCTest
import CoreGraphics
@testable import SnapGeometry

final class GeometryTests: XCTestCase {
    func testEveryLayoutPartitionsScreenWithoutOverlap() {
        for layout in SnapLayout.all {
            XCTAssertEqual(layout.zones.reduce(CGFloat.zero) { $0+$1.width*$1.height }, 1, accuracy: 0.00001, layout.id)
            for (i, zone) in layout.zones.enumerated() {
                XCTAssertGreaterThanOrEqual(zone.minX, 0)
                XCTAssertGreaterThanOrEqual(zone.minY, 0)
                XCTAssertLessThanOrEqual(zone.maxX, 1.00001)
                XCTAssertLessThanOrEqual(zone.maxY, 1.00001)
                for other in layout.zones.dropFirst(i+1) {
                    let overlap = zone.intersection(other)
                    XCTAssertTrue(overlap.isNull || overlap.width*overlap.height < 0.00001, layout.id)
                }
            }
        }
    }
    func testResolutionAndDisplayOriginMatrix() {
        // Includes an 8K 1x display, Retina 8K logical dimensions, ultrawide,
        // a portrait panel, negative X, and a display above the main display.
        let screens = [CGRect(x: 0, y: 25, width: 7680, height: 4295),
                       CGRect(x: 0, y: 25, width: 3840, height: 2135),
                       CGRect(x: -5120, y: 0, width: 5120, height: 1440),
                       CGRect(x: 800, y: -2160, width: 3840, height: 2160),
                       CGRect(x: 1920, y: 0, width: 1080, height: 1920)]
        for screen in screens {
            for scale: CGFloat in [1, 2] {
                for gap: CGFloat in [0, 8, 20] {
                    for layout in SnapLayout.all {
                        let frames = layout.zones.map { Geometry.frame($0, in: screen, gap: gap, scale: scale) }
                        for frame in frames {
                            XCTAssertTrue(screen.contains(frame), "\(layout.id): \(frame)")
                            XCTAssertEqual(frame.minX*scale, (frame.minX*scale).rounded(), accuracy: 0.001)
                            XCTAssertGreaterThan(frame.width, 0)
                        }
                        for (i, a) in frames.enumerated() {
                            for b in frames.dropFirst(i+1) {
                                let overlap = a.intersection(b)
                                XCTAssertTrue(overlap.isNull || overlap.width*overlap.height < 0.001)
                            }
                        }
                    }
                }
            }
        }
    }
    func testSixtyFortyResize() throws {
        let zones = SnapLayout.all[0].zones
        let resized = try XCTUnwrap(Geometry.resized(zones, vertical: true, boundary: 0.5, to: 0.6, minimums: [0.1, 0.1]))
        XCTAssertEqual(resized[0].width, 0.6, accuracy: 0.001)
        XCTAssertEqual(resized[1].width, 0.4, accuracy: 0.001)
        XCTAssertEqual(resized[0].maxX, resized[1].minX)
    }
    func testThirdsResizePreservesOtherBoundary() throws {
        let layout = try XCTUnwrap(SnapLayout.all.first { $0.id == "thirds" })
        let resized = try XCTUnwrap(Geometry.resized(layout.zones, vertical: true, boundary: 1.0/3, to: 0.4, minimums: [0.12, 0.12, 0.12]))
        XCTAssertEqual(resized[0].maxX, 0.4, accuracy: 0.001)
        XCTAssertEqual(resized[1].maxX, 2.0/3, accuracy: 0.001)
        XCTAssertEqual(resized[2], layout.zones[2])
    }
    func testMinimumSizeClampAndImpossibleLayout() throws {
        let zones = SnapLayout.all[0].zones
        let resized = try XCTUnwrap(Geometry.resized(zones, vertical: true, boundary: 0.5, to: 0.95, minimums: [0.2, 0.3]))
        XCTAssertEqual(resized[0].width, 0.7, accuracy: 0.001)
        XCTAssertNil(Geometry.resized(zones, vertical: true, boundary: 0.5, to: 0.6, minimums: [0.6, 0.6]))
    }
    func testGridMovesEntireSharedLine() throws {
        let layout = try XCTUnwrap(SnapLayout.all.first { $0.id == "quarters" })
        let resized = try XCTUnwrap(Geometry.resized(layout.zones, vertical: true, boundary: 0.5, to: 0.6, minimums: []))
        XCTAssertEqual(resized[0].maxX, 0.6, accuracy: 0.001)
        XCTAssertEqual(resized[2].maxX, 0.6, accuracy: 0.001)
        XCTAssertEqual(resized[1].minX, 0.6, accuracy: 0.001)
        XCTAssertEqual(resized[3].minX, 0.6, accuracy: 0.001)
        let rows = try XCTUnwrap(Geometry.resized(resized, vertical: false, boundary: 0.5, to: 0.7, minimums: []))
        XCTAssertEqual(rows[0].height, 0.7, accuracy: 0.001)
        XCTAssertEqual(rows[2].height, 0.3, accuracy: 0.001)
    }
}
