import XCTest
@testable import WispCore

final class DefinitionTests: XCTestCase {
    func testWord() {
        XCTAssertEqual(Definition.word(in: "define ephemeral"), "ephemeral")
        XCTAssertEqual(Definition.word(in: "What's the definition of serendipity?"), "serendipity")
        XCTAssertEqual(Definition.word(in: "what does the word ubiquitous mean"), "ubiquitous")
        XCTAssertNil(Definition.word(in: "define this"))
        XCTAssertNil(Definition.word(in: "what does this button do"))
    }

    func testSpoken() {
        let entry = "ephemeral e·phem·er·al | əˈfem(ə)rəl | adjective lasting for a very short time: fashions are ephemeral. • (chiefly of plants) having a very short life cycle"
        XCTAssertEqual(Definition.spoken(word: "ephemeral", entry: entry), "Ephemeral, adjective: lasting for a very short time.")
    }
}
