import XCTest
@testable import WispCore

final class GestureTests: XCTestCase {
    func testArcLengthParametrisation() {
        let p = TracePath(kind: .freehand, points: [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)])
        XCTAssertEqual(p.length, 200, accuracy: 1e-9)
        XCTAssertEqual(p.point(atFraction: 0.5), Vec2(100, 0))
        XCTAssertEqual(p.point(atFraction: 0.75).y, 50, accuracy: 1e-9)
        XCTAssertEqual(p.prefix(0.25), [Vec2(0, 0), Vec2(50, 0)])
        XCTAssertEqual(p.prefix(1).last, Vec2(100, 100))
        XCTAssertEqual(p.direction(atFraction: 0.25).x, 1, accuracy: 1e-6)
    }

    func testDurationScalesAndClamps() {
        XCTAssertEqual(TracePath.duration(forLength: 10), 0.45)
        XCTAssertEqual(TracePath.duration(forLength: 5000), 1.6)
        XCTAssertLessThan(TracePath.duration(forLength: 300), TracePath.duration(forLength: 700))
    }

    func testCircleSurroundsTheRectAndOverlapsItsStart() {
        let rect = Rect(x: 100, y: 100, width: 200, height: 60)
        let c = GesturePlanner.circle(around: rect)
        XCTAssertEqual(c.kind, .circle)
        for p in c.points {
            // Every pen point is outside (or on) the rect: the circle never covers the target.
            XCTAssertFalse(p.x > rect.minX + 2 && p.x < rect.maxX - 2 && p.y > rect.minY + 2 && p.y < rect.maxY - 2)
        }
        XCTAssertLessThan(c.start.distance(to: c.points.last!), 60, "ends near where it started")
    }

    func testArrowEndsWithHead() {
        let a = GesturePlanner.arrow(from: Vec2(0, 0), to: Vec2(200, 0))
        XCTAssertEqual(a.points[a.points.count - 2], Vec2(200, 0), "pen returns to the tip between head strokes")
        XCTAssertEqual(a.points[28].x, 200, accuracy: 1e-9)
    }

    func testUnderlineGoesLeftToRight() {
        let u = GesturePlanner.underline(from: Vec2(300, 50), to: Vec2(100, 50))
        XCTAssertEqual(u.start.x, 100)
        XCTAssertEqual(u.points.last!.x, 300)
    }

    func testMappingRejectsOutOfRangeAndMapsOnMixedScaleDisplays() {
        // Secondary 1.5x display to the left of the primary, at a negative origin.
        let frame = Rect(x: -1920, y: 200, width: 1920, height: 1080)
        let record = CaptureRecord(displayID: 2, displayFrame: frame, pointPixelScale: 1.5,
                                   capturePixels: PixelSize(width: 2880, height: 1620), sentPixels: PixelSize(width: 1456, height: 819),
                                   cursorGlobal: frame.center, frontmostBundleID: nil, capturedAtUptime: 0)
        guard case .point(let p, _)? = GesturePlanner.gesture(for: .point(x: 728, y: 409.5, label: "x"), record: record, space: .imagePixels) else {
            return XCTFail()
        }
        XCTAssertEqual(p.x, frame.center.x, accuracy: 0.01)
        XCTAssertEqual(p.y, frame.center.y, accuracy: 0.01)
        XCTAssertNil(GesturePlanner.gesture(for: .point(x: 5000, y: 10, label: "x"), record: record, space: .imagePixels))
        XCTAssertNil(GesturePlanner.gesture(for: .say("hi"), record: record, space: .imagePixels))
        guard case .trace(let t, _)? = GesturePlanner.gesture(for: .circle(x: 100, y: 100, width: 200, height: 50, label: "c"),
                                                              record: record, space: .imagePixels) else { return XCTFail() }
        XCTAssertTrue(t.points.allSatisfy { $0.x < 0 }, "drawn on the left display")
    }
}
