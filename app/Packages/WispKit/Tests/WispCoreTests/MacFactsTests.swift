import XCTest
@testable import WispCore

final class MacFactsTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(MacFacts.parse("how much storage do I have left?"), .storage)
        XCTAssertEqual(MacFacts.parse("is my disk full"), .storage)
        XCTAssertEqual(MacFacts.parse("what's my battery"), .battery)
        XCTAssertEqual(MacFacts.parse("what version of macOS do I have"), .macOSVersion)
        XCTAssertEqual(MacFacts.parse("how much RAM does my Mac have"), .memory)
        XCTAssertEqual(MacFacts.parse("how long has my Mac been on"), .uptime)
        XCTAssertNil(MacFacts.parse("how do I free up storage"))
        XCTAssertNil(MacFacts.parse("why is my battery draining"))
    }

    func testFormatting() {
        XCTAssertEqual(MacFacts.duration(3 * 86_400 + 4 * 3600 + 60), "3 days and 4 hours")
        XCTAssertEqual(MacFacts.duration(2 * 3600 + 5 * 60), "2 hours and 5 minutes")
        XCTAssertEqual(MacFacts.duration(30), "1 minute")
        XCTAssertEqual(MacFacts.bytes(26_380_000_000), "26.38 GB")
    }
}
