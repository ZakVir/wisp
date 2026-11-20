import XCTest
@testable import WispCore

final class SpringTests: XCTestCase {
    func testSettlesOnTargetWithinAboutTheResponseTime() {
        var spring = Spring2D(position: .zero, response: 0.2, dampingRatio: 1.0)
        let target = Vec2(300, -120)
        var t = 0.0
        while !spring.isSettled(at: target) && t < 2 {
            spring.step(dt: 1.0 / 120.0, target: target)
            t += 1.0 / 120.0
        }
        XCTAssertLessThan(t, 0.6, "critically damped spring should settle quickly")
        XCTAssertEqual(spring.position.x, 300, accuracy: 0.5)
    }

    func testCriticallyDampedDoesNotOvershoot() {
        var spring = Spring2D(position: .zero, response: 0.25, dampingRatio: 1.0)
        var maxX = 0.0
        for _ in 0..<240 { spring.step(dt: 1.0 / 120.0, target: Vec2(100, 0)); maxX = max(maxX, spring.position.x) }
        XCTAssertLessThanOrEqual(maxX, 100.5)
    }

    func testStableAtLowFrameRates() {
        var spring = Spring2D(position: .zero, response: 0.1, dampingRatio: 0.8)
        for _ in 0..<30 { spring.step(dt: 1.0 / 10.0, target: Vec2(50, 50)) } // 10 fps hiccups
        XCTAssertEqual(spring.position.x, 50, accuracy: 1)
        XCTAssertFalse(spring.position.x.isNaN)
    }
}
