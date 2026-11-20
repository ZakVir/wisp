import XCTest
@testable import WispCore

final class TimeAnswerTests: XCTestCase {
    let chicago = TimeZone(identifier: "America/Chicago")!
    var now: Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = chicago
        return c.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 21, minute: 5))!
    }

    func testTimes() {
        XCTAssertEqual(TimeAnswer.answer("what time is it", now: now, here: chicago), "It's 9:05 PM.")
        XCTAssertEqual(TimeAnswer.answer("What time is it in Tokyo?", now: now, here: chicago), "It's 11:05 AM in Tokyo, Sunday.")
        XCTAssertEqual(TimeAnswer.answer("what's the time in london", now: now, here: chicago), "It's 3:05 AM in London, Sunday.")
        XCTAssertEqual(TimeAnswer.answer("what's the date", now: now, here: chicago), "It's Saturday, October 3, 2026.")
        XCTAssertNil(TimeAnswer.answer("what time is it in narnia", now: now, here: chicago))
        XCTAssertNil(TimeAnswer.answer("what time does the store close", now: now, here: chicago))
    }
}
