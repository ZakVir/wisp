import XCTest
@testable import WispCore

final class WritingHelpTests: XCTestCase {
    func testRequests() {
        for q in ["make this more polite", "Can you fix the grammar?", "translate this into French", "summarize this",
                  "rewrite this", "turn this into bullet points", "make it shorter", "proofread my email",
                  "write a reply to this message", "make this sound more professional", "summarize this page",
                  "translate this page into English", "what are the key points of this email", "give me the gist of this article"] {
            XCTAssertTrue(WritingHelp.isRequest(q), q)
        }
        for q in ["how do I make this bigger", "what does this mean", "read this to me", "make this window full screen",
                  "how do I translate a web page"] {
            XCTAssertFalse(WritingHelp.isRequest(q), q)
        }
    }

    func testSummaryDetection() {
        XCTAssertTrue(WritingHelp.isSummary("summarize this page"))
        XCTAssertTrue(WritingHelp.isSummary("what are the key points of this"))
        XCTAssertFalse(WritingHelp.isSummary("translate this into French"))
    }

    func testCleaning() {
        XCTAssertEqual(WritingHelp.cleaned("Here's a more polite version:\nCould you send it today?"), "Could you send it today?")
        XCTAssertEqual(WritingHelp.cleaned("“Thanks so much!”"), "Thanks so much!")
        XCTAssertEqual(WritingHelp.cleaned("- Book the venue  \n- Order food  "), "- Book the venue\n- Order food")
        XCTAssertEqual(WritingHelp.cleaned("He said \"hi\" and \"bye\""), "He said \"hi\" and \"bye\"")
    }
}
