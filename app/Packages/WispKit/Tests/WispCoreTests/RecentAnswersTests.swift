import XCTest
@testable import WispCore

final class RecentAnswersTests: XCTestCase {
    func testNewestFirstAndCapped() {
        var recent = RecentAnswers()
        for i in 0..<15 { recent.add(question: "q\(i)", sentences: ["a\(i)."]) }
        XCTAssertEqual(recent.entries.count, RecentAnswers.capacity)
        XCTAssertEqual(recent.last?.question, "q14")
        XCTAssertEqual(recent.entries.last?.question, "q5")
    }

    func testEmptyAnswersAreNotKept() {
        var recent = RecentAnswers()
        recent.add(question: "hello", sentences: ["  ", ""])
        XCTAssertNil(recent.last)
        recent.add(question: "hi", sentences: ["One.", "Two."])
        XCTAssertEqual(recent.last?.answer, "One. Two.")
    }

    func testTitles() {
        XCTAssertEqual(RecentAnswers.title(for: "how do i crop this"), "How do i crop this")
        let long = RecentAnswers.title(for: "how do i make the samples in this window a lot bigger than they are now please")
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, 49)
        XCTAssertEqual(RecentAnswers.title(for: " "), "(no words)")
    }
}
