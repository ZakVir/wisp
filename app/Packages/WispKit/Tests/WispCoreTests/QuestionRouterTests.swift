import XCTest
@testable import WispCore

final class QuestionRouterTests: XCTestCase {
    func testQuickHowToQuestionsAreStillRecognised() {
        for q in ["how do I open a tab in Chrome", "How do I view my browser history?", "how do I see my download history",
                  "where's the export button", "what's the shortcut for copy"] {
            XCTAssertTrue(QuestionRouter.isSimple(q), q)
        }
        for q in ["why is my Mac so slow", "explain this chart", "draw a cat", "how do I fix this error"] {
            XCTAssertFalse(QuestionRouter.isSimple(q), q)
        }
    }

    func testEveryQuestionGoesToTheStrongModelFirst() {
        // Quick how-to questions too: the fast model answers them from habit instead of from the screen (FINDINGS §12).
        for q in ["how do I start a new session", "where's the export button", "why is my Mac so slow", "draw a cat"] {
            XCTAssertEqual(QuestionRouter.models(for: q, fallbacks: ["z-ai/glm-5.3-flash", QuestionRouter.fastModelID]),
                           [QuestionRouter.strongModelID, QuestionRouter.fastModelID, "z-ai/glm-5.3-flash"], q)
        }
    }
}
