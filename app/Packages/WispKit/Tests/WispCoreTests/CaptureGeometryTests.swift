import XCTest
@testable import WispCore

/// Coordinate round-trips on single, mixed-scale and oddly arranged multi-display layouts.
final class CaptureGeometryTests: XCTestCase {
    /// Built-in 1710×1112 Retina (scale 2) at the origin.
    let builtIn = Rect(x: 0, y: 0, width: 1710, height: 1112)
    /// External 2560×1440 non-Retina to the right, top-aligned higher.
    let externalRight = Rect(x: 1710, y: -200, width: 2560, height: 1440)
    /// External 1920×1080 placed above-left (negative x, positive y beyond the primary).
    let externalAboveLeft = Rect(x: -800, y: 1112, width: 1920, height: 1080)
    /// Portrait display below the primary (negative y).
    let portraitBelow = Rect(x: 200, y: -1920, width: 1080, height: 1920)

    private func record(_ frame: Rect, scale: Double, longEdge: Int = 1456) -> CaptureRecord {
        let capture = PixelSize(width: Int(frame.width * scale), height: Int(frame.height * scale))
        return CaptureRecord(displayID: 1, displayFrame: frame, pointPixelScale: scale, capturePixels: capture,
                             sentPixels: ImageSizing.fit(capture, longEdge: longEdge),
                             cursorGlobal: frame.center, frontmostBundleID: nil, capturedAtUptime: 0)
    }

    func testFitPreservesAspectAndNeverUpscales() {
        XCTAssertEqual(ImageSizing.fit(PixelSize(width: 3420, height: 2224), longEdge: 1456), PixelSize(width: 1456, height: 946))
        XCTAssertEqual(ImageSizing.fit(PixelSize(width: 1080, height: 1920), longEdge: 1456), PixelSize(width: 820, height: 1456))
        XCTAssertEqual(ImageSizing.fit(PixelSize(width: 800, height: 600), longEdge: 1456), PixelSize(width: 800, height: 600))
    }

    func testCornersAndCenterRoundTripOnEveryLayout() {
        let layouts: [(Rect, Double)] = [(builtIn, 2), (externalRight, 1), (externalAboveLeft, 1.5), (portraitBelow, 2)]
        for (frame, scale) in layouts {
            let r = record(frame, scale: scale)
            let points = [Vec2(frame.minX + 1, frame.minY + 1), Vec2(frame.maxX - 1, frame.maxY - 1),
                          Vec2(frame.minX + 1, frame.maxY - 1), frame.center]
            for p in points {
                let img = r.imagePoint(fromGlobal: p)
                let back = r.globalPoint(fromModel: img.x, img.y)!
                XCTAssertEqual(back.x, p.x, accuracy: 1e-6, "x round trip on \(frame)")
                XCTAssertEqual(back.y, p.y, accuracy: 1e-6, "y round trip on \(frame)")
                XCTAssertTrue(frame.contains(back), "lands on the same display")
            }
        }
    }

    func testImageOriginIsTopLeft() {
        let r = record(builtIn, scale: 2)
        let topLeft = r.globalPoint(fromModel: 0, 0)!
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 1111.5, accuracy: 1e-9, "image y=0 is the top row of the display")
        let bottomRight = r.globalPoint(fromModel: Double(r.sentPixels.width), Double(r.sentPixels.height))!
        XCTAssertLessThan(bottomRight.x, builtIn.maxX)
        XCTAssertGreaterThan(bottomRight.y, builtIn.minY)
    }

    func testRetinaScaleDoesNotChangeTheMapping() {
        // Same display frame captured at scale 1 and 2 → same global point for the same fraction.
        let r1 = record(builtIn, scale: 1)
        let r2 = record(builtIn, scale: 2)
        let a = r1.globalPoint(fromModel: Double(r1.sentPixels.width) * 0.3, Double(r1.sentPixels.height) * 0.7)!
        let b = r2.globalPoint(fromModel: Double(r2.sentPixels.width) * 0.3, Double(r2.sentPixels.height) * 0.7)!
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
    }

    func testNormalizedSpaces() {
        let r = record(externalRight, scale: 1)
        let center1000 = r.globalPoint(fromModel: 500, 500, space: .normalized1000)!
        XCTAssertEqual(center1000.x, externalRight.center.x, accuracy: 1e-6)
        XCTAssertEqual(center1000.y, externalRight.center.y, accuracy: 1e-6)
        let centerUnit = r.globalPoint(fromModel: 0.5, 0.5, space: .normalizedUnit)!
        XCTAssertEqual(centerUnit.x, externalRight.center.x, accuracy: 1e-6)
    }

    func testOutOfRangeIsClampedOntoTheSameDisplayAndNaNRejected() {
        let r = record(builtIn, scale: 2)
        let far = r.globalPoint(fromModel: 99_999, -50)!
        XCTAssertTrue(builtIn.contains(far))
        XCTAssertNil(r.globalPoint(fromModel: .nan, 3))
        XCTAssertNil(r.globalPoint(fromModel: .infinity, 3))
        XCTAssertFalse(r.isInRange(2000, 10, space: .imagePixels))
        XCTAssertTrue(r.isInRange(2000 / 2, 10, space: .imagePixels))
    }

    func testCursorInImage() {
        var r = record(builtIn, scale: 2)
        r.cursorGlobal = Vec2(855, 556) // centre
        let c = r.cursorInImage!
        XCTAssertEqual(c.x, Double(r.sentPixels.width) / 2, accuracy: 0.01)
        XCTAssertEqual(c.y, Double(r.sentPixels.height) / 2, accuracy: 0.01)
        r.cursorGlobal = Vec2(5000, 5000)
        XCTAssertNil(r.cursorInImage, "pointer on another display")
    }

    func testRectMapping() {
        let r = record(builtIn, scale: 2)
        let rect = r.globalRect(fromModel: 100, 100, width: 200, height: 50)!
        XCTAssertEqual(rect.width, 200 / r.resizeFactor, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 50 * builtIn.height / Double(r.sentPixels.height), accuracy: 1e-6)
    }
}
