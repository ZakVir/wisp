import XCTest
@testable import WispCore

final class QuickMathTests: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(QuickMath.answer("what's 15% of 80?"), "15% of 80 is 12.")
        XCTAssertEqual(QuickMath.answer("What is 15 percent of 80"), "15% of 80 is 12.")
        XCTAssertEqual(QuickMath.answer("what's 128 times 7"), "128 times 7 is 896.")
        XCTAssertEqual(QuickMath.answer("calculate (2 + 3) * 4"), "(2 plus 3) times 4 is 20.")
        XCTAssertEqual(QuickMath.answer("what's 10 divided by 4"), "10 divided by 4 is 2.5.")
        XCTAssertEqual(QuickMath.answer("what's the square root of 81"), "the square root of 81 is 9.")
        XCTAssertEqual(QuickMath.answer("what's 2 to the power of 10"), "2 to the power of 10 is 1024.")
        XCTAssertNil(QuickMath.answer("what's 5 divided by 0"))
        XCTAssertNil(QuickMath.answer("what's this button"))
        XCTAssertNil(QuickMath.answer("what is 42"), "a lone number isn't a calculation")
        XCTAssertNil(QuickMath.answer("what's the time"))
    }

    func testNumberWords() {
        XCTAssertEqual(QuickMath.answer("what's two plus two"), "2 plus 2 is 4.")
        XCTAssertEqual(QuickMath.answer("what is twenty five percent of eighty"), "25% of 80 is 20.")
        XCTAssertEqual(QuickMath.answer("what's two hundred and ten divided by seven"), "210 divided by 7 is 30.")
        XCTAssertEqual(QuickMath.answer("convert three point five miles to km"), "3.5 miles is 5.63270 kilometers.".replacingOccurrences(of: "5.63270", with: "5.6327"))
        XCTAssertNil(QuickMath.answer("what's one thing I should know"))
    }

    func testTipsAndDays() {
        XCTAssertEqual(QuickMath.answer("what's a 20% tip on 45 dollars"), "A 20% tip on $45 is $9.00, for a total of $54.00.")
        XCTAssertEqual(QuickMath.answer("tip on $80"), "An 18% tip on $80 is $14.40, for a total of $94.40.")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 3))!
        XCTAssertEqual(QuickMath.answer("how many days until christmas", now: now, calendar: cal), "83 days, until Friday, December 25.")
        XCTAssertEqual(QuickMath.answer("how many days until October 4th", now: now, calendar: cal), "1 day, until Sunday, October 4.")
        XCTAssertNil(QuickMath.answer("how many days until my vacation", now: now, calendar: cal))
    }

    func testDaysUntilDoesNotDependOnTheSystemTimeZone() {
        // The date text is read in the calendar's zone, whatever zone the Mac (or a CI machine) is set to.
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        defer { NSTimeZone.default = saved }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 3))!
        XCTAssertEqual(QuickMath.answer("how many days until October 4th", now: now, calendar: cal), "1 day, until Sunday, October 4.")
    }

    func testConversions() {
        XCTAssertEqual(QuickMath.answer("convert 5 miles to kilometers"), "5 miles is 8.04672 kilometers.")
        XCTAssertEqual(QuickMath.answer("what's 72 fahrenheit in celsius"), "72 degrees Fahrenheit is 22.2222 degrees Celsius.")
        XCTAssertEqual(QuickMath.answer("how many ounces in a pound"), "1 pound is 16 ounces.")
        XCTAssertEqual(QuickMath.answer("10 km in miles"), "10 kilometers is 6.21371 miles.")
        XCTAssertNil(QuickMath.answer("convert 5 miles to kilograms"), "different kinds of unit")
        XCTAssertNil(QuickMath.answer("how do I convert this file to pdf"))
    }
}
