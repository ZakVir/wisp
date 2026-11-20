import XCTest
@testable import WispMac

final class WispMacSmokeTests: XCTestCase {
    func testAppPathsAreUnderApplicationSupport() {
        XCTAssertTrue(AppPaths.models.path.hasSuffix("Application Support/Wisp/Models"))
    }
}
