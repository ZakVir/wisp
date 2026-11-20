import XCTest
@testable import WispCore

final class TimerTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(TimerCommand.parse("set a timer for 5 minutes"), .set(seconds: 300, label: nil))
        XCTAssertEqual(TimerCommand.parse("Set a timer for twenty five minutes."), .set(seconds: 1500, label: nil))
        XCTAssertEqual(TimerCommand.parse("start a 10 minute timer"), .set(seconds: 600, label: nil))
        XCTAssertEqual(TimerCommand.parse("set a timer for half an hour"), .set(seconds: 1800, label: nil))
        XCTAssertEqual(TimerCommand.parse("remind me in 20 minutes to call Sam"), .set(seconds: 1200, label: "call Sam"))
        XCTAssertEqual(TimerCommand.parse("remind me to check my email in 2 hours"), .set(seconds: 7200, label: "check your email"))
        XCTAssertEqual(TimerCommand.parse("remind me at 3 pm to send the report"), .at(hour: 15, minute: 0, label: "send the report"))
        XCTAssertEqual(TimerCommand.parse("remind me to stretch at 4:30"), .at(hour: 4, minute: 30, label: "stretch"))
        XCTAssertEqual(TimerCommand.parse("cancel my timer"), .cancel)
        XCTAssertEqual(TimerCommand.parse("snooze"), .snooze(seconds: 600))
        XCTAssertEqual(TimerCommand.parse("snooze for 5 minutes"), .snooze(seconds: 300))
        XCTAssertEqual(TimerCommand.parse("add two minutes to my timer"), .extend(seconds: 120))
        XCTAssertEqual(TimerCommand.parse("how much time is left"), .status)
        XCTAssertNil(TimerCommand.parse("how do I set a timer in the Clock app"))
        XCTAssertNil(TimerCommand.parse("remind me what this button does"))
    }

    func testNextDateAndSpoken() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 14, minute: 0))!
        let at430 = TimerCommand.nextDate(hour: 4, minute: 30, after: now, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: at430), 16, "4:30 without am/pm means the next one: 4:30 pm")
        let at3pm = TimerCommand.nextDate(hour: 15, minute: 0, after: now, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: at3pm), 15)
        XCTAssertEqual(TimerCommand.spoken(300), "5 minutes")
        XCTAssertEqual(TimerCommand.spoken(5400), "1 hour 30 minutes")
        XCTAssertEqual(TimerCommand.spoken(45), "45 seconds")
    }
}
