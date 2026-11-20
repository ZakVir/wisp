import XCTest
@testable import WispCore

final class UIContextTests: XCTestCase {
    // A 1000 × 500 pt display captured at 1000 × 500 px; AppKit coordinates (y up).
    let record = CaptureRecord(displayID: 1, displayFrame: Rect(x: 0, y: 0, width: 1000, height: 500), pointPixelScale: 2,
                               capturePixels: PixelSize(width: 1000, height: 500), sentPixels: PixelSize(width: 1000, height: 500),
                               cursorGlobal: Vec2(0, 0), frontmostBundleID: nil, capturedAtUptime: 0)
    // "Erase" near the top-left (AppKit y 440…460 = 40…60 px from the top), "Restore" greyed, one off-screen.
    let context = UIContext(appName: "Disk Utility", elements: [
        .init(kind: "button", label: "Restore", enabled: false, frame: Rect(x: 200, y: 440, width: 60, height: 20)),
        .init(kind: "button", label: "Erase", frame: Rect(x: 100, y: 440, width: 60, height: 20)),
        .init(kind: "button", label: "Off screen", frame: Rect(x: 2000, y: 100, width: 60, height: 20)),
    ], menus: [.init(menu: "File", title: "New Image"), .init(menu: "Edit", title: "Erase…", shortcut: "⇧⌘E")])

    func testControlsInReadingOrderAndModelCoordinates() {
        let lines = UIContextFormat.controlLines(context, record: record, space: .normalized1000)
        XCTAssertEqual(lines.map(\.label), ["Erase", "Restore"], "left to right on one row; off-screen dropped")
        XCTAssertEqual(lines[0].x, 130, accuracy: 0.5)
        XCTAssertEqual(lines[0].y, 100, accuracy: 0.5) // 50 px from the top of 500 → 100 in 0–1000
        XCTAssertFalse(lines[1].enabled)
        let text = UIContextFormat.text(appName: "Disk Utility", controls: lines, menus: context.menus, space: .normalized1000)
        XCTAssertTrue(text.contains("button \"Restore\" (greyed out) at 230, 100"), text)
        XCTAssertTrue(text.contains("- Edit: Erase… ⇧⌘E"), text)
        XCTAssertTrue(text.contains("- File: New Image"), text)
    }

    func testPointsMoveOntoTheControlTheyName() {
        let lines = UIContextFormat.controlLines(context, record: record, space: .normalized1000)
        let turn = VisualDecision.Turn(question: "how do I wipe it", topicSaysOther: false, controls: lines, reach: 120)
        let moved = VisualDecision.decide(.point(x: 160, y: 120, label: "Erase button"), after: "Click Erase.", turn: turn) { _ in false }
        XCTAssertEqual(moved, .point(x: 130, y: 100, label: "Erase button"))
        let far = VisualDecision.decide(.point(x: 800, y: 400, label: "Erase"), after: "Click Erase.", turn: turn) { _ in false }
        XCTAssertEqual(far, .point(x: 130, y: 100, label: "Erase"), "a unique name decides even when the coordinates are off")
        // Three controls with the same name, none near the point: nothing to go on, so the point stays.
        let many = (0..<3).map { ControlLine(kind: "button", label: "Play", state: nil, enabled: true, x: Double(100 + 50 * $0), y: 900) }
        let manyTurn = VisualDecision.Turn(question: "play it", topicSaysOther: false, controls: many, reach: 120)
        XCTAssertEqual(VisualDecision.decide(.point(x: 800, y: 100, label: "Play"), after: "Click Play.", turn: manyTurn) { _ in false },
                       .point(x: 800, y: 100, label: "Play"))
    }

    func testOtherAnswersNeedTheThingToBeThere() {
        let lines = UIContextFormat.controlLines(context, record: record, space: .normalized1000)
        let turn = VisualDecision.Turn(question: "what's erase", topicSaysOther: true, controls: lines, reach: 120)
        XCTAssertNotNil(VisualDecision.decide(.point(x: 140, y: 110, label: "Erase"), after: "Erase wipes the disk.", turn: turn) { _ in false })
        XCTAssertNil(VisualDecision.decide(.point(x: 500, y: 300, label: "llama"), after: "A llama is an animal.", turn: turn) { _ in false })
        let about = VisualDecision.Turn(question: "what can you do", topicSaysOther: false, controls: lines, reach: 120)
        XCTAssertNil(VisualDecision.decide(.point(x: 130, y: 100, label: "Erase"), after: "I can help.", turn: about) { _ in true })
        let plain = VisualDecision.Turn(question: "is there an undo", topicSaysOther: false, controls: lines, reach: 120)
        XCTAssertNil(VisualDecision.decide(.point(x: 130, y: 100, label: "Undo"), after: "I don't see an Undo button.", turn: plain) { _ in true })
    }
}

final class GreyedOutNoteTests: XCTestCase {
    func testNoteOnlyWhenTheAnswerDoesntSaySo() {
        let back = ControlLine(kind: "button", label: "Back", state: nil, enabled: false, x: 500, y: 320)
        let turn = VisualDecision.Turn(question: "go back", topicSaysOther: false, controls: [back], reach: 120)
        let shown = AssistantEvent.point(x: 500, y: 320, label: "Back")
        XCTAssertEqual(VisualDecision.greyedOutTarget(shown, turn: turn)?.label, "Back")
        XCTAssertEqual(VisualDecision.greyedOutNote(labels: ["Back"], answer: ["Click the Back button."]),
                       "Back is greyed out right now, so it can't be used yet.")
        XCTAssertNil(VisualDecision.greyedOutNote(labels: ["Back"], answer: ["Back is greyed out, so there's nothing to go back to."]))
        XCTAssertNil(VisualDecision.greyedOutNote(labels: [], answer: ["Click Save."]))
        let enabled = VisualDecision.Turn(question: "go back", topicSaysOther: false,
                                          controls: [ControlLine(kind: "button", label: "Back", state: nil, enabled: true, x: 500, y: 320)], reach: 120)
        XCTAssertNil(VisualDecision.greyedOutTarget(shown, turn: enabled))
    }
}
