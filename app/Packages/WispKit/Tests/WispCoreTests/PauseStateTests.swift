import XCTest
@testable import WispCore

final class PauseStateTests: XCTestCase {
    func testEnds() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 22, minute: 15))!
        XCTAssertEqual(PauseState.end(of: .hour, from: now), now.addingTimeInterval(3600))
        let tomorrow = PauseState.end(of: .tomorrow, from: now, calendar: cal)
        XCTAssertEqual(cal.dateComponents([.day, .hour], from: tomorrow), DateComponents(day: 4, hour: 6))
        XCTAssertEqual(PauseState.end(of: .indefinitely, from: now), .distantFuture)
        XCTAssertEqual(PauseState.description(until: .distantFuture, now: now), "Paused")
        XCTAssertTrue(PauseState.description(until: tomorrow, now: now, calendar: cal).hasPrefix("Paused until tomorrow"))
    }
}
