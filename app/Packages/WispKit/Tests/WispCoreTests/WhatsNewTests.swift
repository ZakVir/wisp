import XCTest
@testable import WispCore

final class WhatsNewTests: XCTestCase {
    func testCompare() {
        XCTAssertEqual(WhatsNew.compare("0.3.10", "0.3.9"), .orderedDescending)
        XCTAssertEqual(WhatsNew.compare("0.4", "0.4.0"), .orderedSame)
        XCTAssertEqual(WhatsNew.compare("0.3.2", "0.4.0"), .orderedAscending)
    }

    func testSince() {
        let shown = WhatsNew.since("0.3.5", upTo: "0.3.7").map(\.version)
        XCTAssertEqual(shown, ["0.3.7", "0.3.6"])
        XCTAssertTrue(WhatsNew.since("0.3.8", upTo: "0.3.8").isEmpty)
    }

    func testEntriesAreNewestFirstAndUnique() {
        let versions = WhatsNew.entries.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count)
        XCTAssertEqual(versions, versions.sorted { WhatsNew.compare($0, $1) == .orderedDescending })
    }
}
