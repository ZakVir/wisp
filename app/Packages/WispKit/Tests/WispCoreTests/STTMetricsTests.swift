import XCTest
@testable import WispCore

final class STTMetricsTests: XCTestCase {
    func testWordsAndWER() {
        XCTAssertEqual(STTMetrics.words("Open the File menu, then Save As."), ["open", "the", "file", "menu", "then", "save", "as"])
        XCTAssertEqual(STTMetrics.wer(reference: "where is the export button", hypothesis: "where is the export button"), 0)
        XCTAssertEqual(STTMetrics.wer(reference: "where is the export button", hypothesis: "where is export button"), 0.2, accuracy: 1e-9)
        XCTAssertEqual(STTMetrics.wer(reference: "a b", hypothesis: "a c d"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(STTMetrics.words("Where's it?"), ["wheres", "it"])
    }

    func testEntities() {
        XCTAssertTrue(STTMetrics.containsEntity("Save As", in: "click save as now"))
        XCTAssertFalse(STTMetrics.containsEntity("Save As", in: "save the file as"))
        XCTAssertTrue(STTMetrics.containsEntity("PDF", in: "export it as a pdf."))
        XCTAssertTrue(STTMetrics.containsEntity("QuickTime", in: "open quick time"))
        XCTAssertTrue(STTMetrics.containsEntity("DaVinci Resolve", in: "in da vinci resolve"))
        XCTAssertFalse(STTMetrics.containsEntity("Word", in: "inward"))
    }

    func testCorpusParsing() {
        let items = STTMetrics.parseCorpus("# comment\nWhere is Export? | Export\nNo entities here\n\nOpen Pages | Pages; Open")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].entities, ["Export"])
        XCTAssertEqual(items[1].entities, [])
        XCTAssertEqual(items[2].entities, ["Pages", "Open"])
    }
}
