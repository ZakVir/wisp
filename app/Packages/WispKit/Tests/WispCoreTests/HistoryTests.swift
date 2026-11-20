import XCTest
@testable import WispCore

final class HistoryTests: XCTestCase {
    func testAddSearchRemoveAndSave() throws {
        var h = History()
        h.add(.init(question: "how do I crop this", answer: "Choose Tools, then Crop.", app: "Preview", typed: false))
        h.add(.init(question: "what's the weather like", answer: "Sunny.", app: "Safari", typed: true))
        h.add(.init(question: "empty", answer: "  ", app: nil, typed: false))
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h.entries.first?.question, "what's the weather like")
        XCTAssertEqual(h.search("crop preview").map(\.question), ["how do I crop this"])
        XCTAssertEqual(h.search("").count, 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).json")
        try h.save(to: url)
        XCTAssertEqual(History.load(from: url), h)
        h.remove(h.entries[0].id)
        XCTAssertEqual(h.entries.count, 1)
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(History.load(from: url).entries.count, 0)
    }

    func testRecall() {
        XCTAssertEqual(History.recallTopic("what did you tell me about cropping earlier?"), "cropping")
        XCTAssertNil(History.recallTopic("what did I do yesterday"))
        var h = History()
        h.add(.init(question: "how do I crop this", answer: "Choose Tools, then Crop.", app: "Preview", typed: false))
        h.add(.init(question: "what's the weather", answer: "Sunny.", app: nil, typed: false))
        XCTAssertEqual(h.recall("cropping")?.answer, "Choose Tools, then Crop.")
        XCTAssertNil(h.recall("printing"))
    }

    func testCapacity() {
        var h = History()
        for i in 0..<(History.capacity + 5) { h.add(.init(question: "q\(i)", answer: "a", app: nil, typed: false)) }
        XCTAssertEqual(h.entries.count, History.capacity)
    }
}
