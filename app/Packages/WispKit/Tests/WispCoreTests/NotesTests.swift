import XCTest
@testable import WispCore

final class NotesTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Notes.parse("remember that my parking spot is B12"), .add("your parking spot is B12"))
        XCTAssertEqual(Notes.parse("Note that I'm meeting Sam at 4."), .add("you're meeting Sam at 4"))
        XCTAssertEqual(Notes.parse("what did I ask you to remember?"), .list)
        XCTAssertEqual(Notes.parse("clear my notes"), .clear)
        XCTAssertNil(Notes.parse("remember this"), "too short to be a note")
        XCTAssertNil(Notes.parse("remember to buy milk"), "that's a reminder without a time, not a note")
        XCTAssertNil(Notes.parse("how do I take notes in this app"))
    }

    func testForgetOne() {
        XCTAssertEqual(Notes.parse("forget the note about parking"), .forget("parking"))
        var n = Notes()
        n.add("your parking spot is B12")
        n.add("the code is 4417")
        XCTAssertEqual(n.forget("parking")?.text, "your parking spot is B12")
        XCTAssertEqual(n.items.count, 1)
        XCTAssertNil(n.forget("birthday"))
    }

    func testSpokenAndSave() throws {
        var n = Notes()
        XCTAssertTrue(n.spoken.hasPrefix("You haven't"))
        n.add("your parking spot is B12")
        n.add("the code is 4417")
        XCTAssertEqual(n.spoken, "You asked me to remember: the code is 4417. And: your parking spot is B12.")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).json")
        try n.save(to: url)
        XCTAssertEqual(Notes.load(from: url), n)
        try? FileManager.default.removeItem(at: url)
    }
}
