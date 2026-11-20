import XCTest
@testable import WispCore

final class GuideTests: XCTestCase {
    func testTaskQuestions() {
        XCTAssertTrue(GuideSession.isTask("How do I export this as a PDF"))
        XCTAssertTrue(GuideSession.isTask("walk me through setting up a printer"))
        XCTAssertTrue(GuideSession.isTask("how do I start a new session"))
        XCTAssertTrue(GuideSession.isTask("I’d like to change my wallpaper"))
        XCTAssertFalse(GuideSession.isTask("what's this button"))
        XCTAssertFalse(GuideSession.isTask("tell me a joke"))
    }

    func testContinuationPhrases() {
        for q in ["What now?", "okay, what's next", "I did it.", "next", "Done.", "what do I do now", "then what?", "Next step please"] {
            XCTAssertTrue(GuideSession.isContinuation(q), q)
        }
        for q in ["what's the weather", "how do I export this", "next to the button, what is that", "done with this app, close it"] {
            XCTAssertFalse(GuideSession.isContinuation(q), q)
        }
    }

    func testClicksAnywhereCountAndSayWhereTheyLanded() {
        var g = GuideSession(goal: "how do i export", said: "Open the File menu.", target: Vec2(100, 100), targetLabel: "File")
        XCTAssertFalse(g.hasActed)
        g.clicked(at: Vec2(130, 90))
        g.clicked(at: Vec2(600, 600))
        g.record(.key("Return"))
        XCTAssertTrue(g.hasActed)
        XCTAssertEqual(g.actionsText, "clicked the highlighted File, then clicked somewhere else, then pressed Return")
    }

    func testTypingIsRecordedOnceAndNeverItsText() {
        var g = GuideSession(goal: "x", said: "Type a name.", target: nil, targetLabel: "")
        g.record(.typing); g.record(.typing); g.record(.typing)
        XCTAssertEqual(g.actionsText, "typed something")
    }

    func testAdvanceKeepsHistoryAndStepNumbers() {
        var g = GuideSession(goal: "how do I start a new session", said: "Click New session.", target: Vec2(0, 0), targetLabel: "New session")
        XCTAssertEqual(g.stepNumber, 1)
        g.clicked(at: Vec2(5, 5))
        g.advance(said: "Now type your first message.", target: nil, targetLabel: "")
        XCTAssertEqual(g.stepNumber, 2)
        XCTAssertFalse(g.hasActed)
        let text = g.requestText
        XCTAssertTrue(text.contains("\"how do I start a new session\""))
        XCTAssertTrue(text.contains("1. You said: \"Click New session.\" They clicked the highlighted New session."))
        XCTAssertTrue(text.contains("Just now you said: \"Now type your first message.\" Since then they did nothing yet."))
        XCTAssertTrue(text.contains("STEPS: done"))
    }

    func testRepeatedStepDoesNotCountAsProgress() {
        var g = GuideSession(goal: "x", said: "Click Save.", target: Vec2(0, 0), targetLabel: "Save")
        g.clicked(at: Vec2(500, 500))
        g.repeatStep(said: "Click Save, at the bottom right.", target: Vec2(10, 10), targetLabel: "Save")
        XCTAssertEqual(g.stepNumber, 1)
        XCTAssertFalse(g.hasActed)
    }

    func testRepeatOfAClickedStepIsRecognised() {
        var g = GuideSession(goal: "wipe the disk", said: "Click Erase in the toolbar.", target: Vec2(500, 700), targetLabel: "Erase")
        XCTAssertFalse(g.isRepeat(of: Vec2(500, 700), label: "Erase"), "not clicked yet: saying it again is fine")
        g.clicked(at: Vec2(505, 702))
        XCTAssertTrue(g.clickedTarget)
        XCTAssertTrue(g.isRepeat(of: Vec2(520, 690), label: "Erase button"), "same spot")
        XCTAssertTrue(g.isRepeat(of: nil, label: "erase"), "same control by name")
        XCTAssertFalse(g.isRepeat(of: Vec2(900, 300), label: "Erase Volume"), "the next control in the sheet")
        XCTAssertTrue(g.requestText.contains("They clicked \"Erase\", the control you showed, so that step is done"))
    }

    func testAKeyCountsAsActingButIsNotAClickOnTheStep() {
        var g = GuideSession(goal: "x", said: "Press Return.", target: nil, targetLabel: "")
        g.record(.key("Return"))
        XCTAssertTrue(g.usedTheStep)
        XCTAssertFalse(g.clickedTarget)
        XCTAssertFalse(g.requestText.contains("so that step is done"))
    }

    func testStepLimit() {
        var g = GuideSession(goal: "x", said: "a", target: nil, targetLabel: "")
        for _ in 0..<(GuideSession.maxSteps - 1) { g.advance(said: "b", target: nil, targetLabel: "") }
        XCTAssertTrue(g.isAtLimit)
    }

    func testStepsLineIsParsedAndNeverSpoken() {
        XCTAssertEqual(ResponseParser.parseLine("STEPS: more"), .steps(more: true))
        XCTAssertEqual(ResponseParser.parseLine("STEPS: done"), .steps(more: false))
        XCTAssertEqual(ResponseParser.parseLine("Steps: Done."), .steps(more: false))
        XCTAssertEqual(ResponseParser.parseLine("STEPS: maybe"), .steps(more: false), "unclear means done: never leave them waiting")
        XCTAssertFalse(AssistantEvent.steps(more: true).isVisual)
        XCTAssertNil(AssistantEvent.steps(more: true).label)
    }

    func testFingerprintIgnoresTinyChangesAndSeesRealOnes() {
        let n = ScreenFingerprint.width * ScreenFingerprint.height
        let a = ScreenFingerprint(pixels: Array(repeating: 100, count: n))
        var caret = a.pixels; caret[500] = 255
        XCTAssertFalse(ScreenFingerprint(pixels: caret).changed(from: a), "a blinking caret is not a change")
        var menu = a.pixels; for i in 0..<300 { menu[i] = 230 }
        XCTAssertTrue(ScreenFingerprint(pixels: menu).changed(from: a), "a menu opening is")
        XCTAssertTrue(ScreenFingerprint(pixels: []).changed(from: a))
    }
}
