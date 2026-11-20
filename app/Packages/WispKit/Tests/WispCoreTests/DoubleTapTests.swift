import XCTest
@testable import WispCore

final class DoubleTapTests: XCTestCase {
    func testDoubleTapControl() {
        var d = DoubleTapDetector(key: .control)
        XCTAssertFalse(d.modifiersChanged(.control, at: 0))
        XCTAssertFalse(d.modifiersChanged([], at: 0.1))
        XCTAssertFalse(d.modifiersChanged(.control, at: 0.25))
        XCTAssertTrue(d.modifiersChanged([], at: 0.33))
        // A third tap starts over.
        XCTAssertFalse(d.modifiersChanged(.control, at: 0.5))
        XCTAssertFalse(d.modifiersChanged([], at: 0.55))
    }

    func testSlowTapsOrLongHoldsDontCount() {
        var d = DoubleTapDetector(key: .control)
        _ = d.modifiersChanged(.control, at: 0); _ = d.modifiersChanged([], at: 0.1)
        _ = d.modifiersChanged(.control, at: 0.9)
        XCTAssertFalse(d.modifiersChanged([], at: 1.0), "second press came too late")
        var h = DoubleTapDetector(key: .control)
        _ = h.modifiersChanged(.control, at: 0); _ = h.modifiersChanged([], at: 0.8) // a hold, not a tap
        _ = h.modifiersChanged(.control, at: 0.9)
        XCTAssertFalse(h.modifiersChanged([], at: 1.0))
    }

    func testChordsAndShortcutsDontCount() {
        var d = DoubleTapDetector(key: .control)
        _ = d.modifiersChanged(.control, at: 0); _ = d.modifiersChanged([.control, .option], at: 0.05)
        _ = d.modifiersChanged(.control, at: 0.1); _ = d.modifiersChanged([], at: 0.15)
        _ = d.modifiersChanged(.control, at: 0.2)
        XCTAssertFalse(d.modifiersChanged([], at: 0.25), "the first press was part of Control + Option")
        var k = DoubleTapDetector(key: .control)
        _ = k.modifiersChanged(.control, at: 0); k.keyPressed(); _ = k.modifiersChanged([], at: 0.1) // Control-C
        _ = k.modifiersChanged(.control, at: 0.2)
        XCTAssertFalse(k.modifiersChanged([], at: 0.25))
    }
}
