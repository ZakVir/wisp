import XCTest
@testable import WispCore

final class LittleHelpersTests: XCTestCase {
    func testHelpers() {
        XCTAssertEqual(LittleHelpers.answer("how do you spell necessary?"), "Necessary is spelled N, E, C, E, S, S, A, R, Y.")
        XCTAssertEqual(LittleHelpers.answer("flip a coin", random: { _ in 0 }), "Heads.")
        XCTAssertEqual(LittleHelpers.answer("roll a die", random: { _ in 4 }), "You rolled a 4.")
        XCTAssertEqual(LittleHelpers.answer("pick a number between 1 and 10", random: { r in r.upperBound }), "10.")
        XCTAssertNil(LittleHelpers.answer("how do I spell check this document"))
        XCTAssertNil(LittleHelpers.answer("what's a coin"))
    }
}
