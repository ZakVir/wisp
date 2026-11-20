import XCTest
@testable import WispCore

final class SelectionContextTests: XCTestCase {
    func testSelectionIsCollapsedAndCut() {
        XCTAssertNil(UIContext.cleanSelection("  \n "))
        XCTAssertEqual(UIContext.cleanSelection("ephemeral\n  word"), "ephemeral word")
        let long = String(repeating: "word ", count: 600)
        let cut = UIContext.cleanSelection(long)!
        XCTAssertTrue(cut.hasSuffix(" …"))
        XCTAssertLessThanOrEqual(cut.count, UIContext.maxSelectedText + 2)
    }

    func testRequestNamesPointerTargetAndSelection() {
        let pointer = ControlLine(kind: "button", label: "Export", state: nil, enabled: false, x: 120, y: 40)
        let text = UIContextFormat.text(appName: "Preview", controls: [], menus: [], space: .imagePixels,
                                        selectedText: "photosynthesis", underPointer: pointer)
        XCTAssertTrue(text.contains("Under the mouse pointer: button \"Export\" (greyed out) at 120, 40"), text)
        XCTAssertTrue(text.contains("Text they have selected in Preview: \"photosynthesis\""), text)
    }

    func testOldCapturesStillDecode() throws {
        let json = #"{"appName":"Clock","elements":[],"menus":[]}"#
        let ui = try JSONDecoder().decode(UIContext.self, from: Data(json.utf8))
        XCTAssertNil(ui.selectedText)
        XCTAssertTrue(ui.isEmpty)
    }
}

final class InstructionsPromptTests: XCTestCase {
    func testInstructionsGoWithTheQuestionWhenSet() {
        var facts = TurnFacts(imageSize: PixelSize(width: 100, height: 100), cursorInImage: nil, frontmostAppName: nil, question: "hi")
        XCTAssertFalse(PromptBuilder.userText(facts).contains("told you about themselves"))
        facts.userInstructions = "  I'm new to Macs.  "
        let text = PromptBuilder.userText(facts)
        XCTAssertTrue(text.contains("\"I'm new to Macs.\""), text)
        XCTAssertTrue(text.hasSuffix("The user asked: \"hi\""), "the question stays last")
    }
}

final class AnswerLengthTests: XCTestCase {
    func testLengthPreferenceLine() {
        var facts = TurnFacts(imageSize: PixelSize(width: 10, height: 10), cursorInImage: nil, frontmostAppName: nil, question: "q")
        XCTAssertFalse(PromptBuilder.userText(facts).contains("prefer"))
        facts.answerLength = "short"
        XCTAssertTrue(PromptBuilder.userText(facts).contains("very short answers"))
        facts.answerLength = "detailed"
        XCTAssertTrue(PromptBuilder.userText(facts).contains("up to four sentences"))
    }
}

final class PrivateAppPromptTests: XCTestCase {
    func testPrivateFrontAppIsExplained() {
        var facts = TurnFacts(imageSize: PixelSize(width: 10, height: 10), cursorInImage: nil, frontmostAppName: "1Password", question: "q")
        XCTAssertFalse(PromptBuilder.userText(facts).contains("private"))
        facts.privateFrontApp = true
        XCTAssertTrue(PromptBuilder.userText(facts).contains("left out of the screenshot"))
    }
}

final class PointerUnitsTests: XCTestCase {
    func testPointerIsGivenInTheModelsUnits() {
        let facts = TurnFacts(imageSize: PixelSize(width: 1456, height: 946), cursorInImage: Vec2(728, 473), frontmostAppName: nil, question: "what's this")
        XCTAssertTrue(PromptBuilder.userText(facts, space: .imagePixels).contains("pointer is at 728, 473"))
        XCTAssertTrue(PromptBuilder.userText(facts, space: .normalized1000).contains("pointer is at 500, 500"))
        XCTAssertTrue(PromptBuilder.userText(facts, space: .normalizedUnit).contains("pointer is at 0.500, 0.500"))
    }
}
