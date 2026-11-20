import XCTest
@testable import WispCore

final class ChordStateMachineTests: XCTestCase {
    private let co: ModifierSet = [.control, .option]

    private func run(_ machine: inout ChordStateMachine, _ inputs: [KeyInput]) -> [ChordEvent] {
        inputs.compactMap { machine.handle($0) }
    }

    func testHoldBeginsOnFullChordAndEndsOnRelease() {
        var m = ChordStateMachine(chord: .controlOption)
        let events = run(&m, [
            .modifiersChanged([.control], at: 0.00),
            .modifiersChanged(co, at: 0.25),
            .modifiersChanged([.option], at: 2.25),
            .modifiersChanged([], at: 2.10),
        ])
        XCTAssertEqual(events, [.began(at: 0.25), .ended(at: 2.25, heldFor: 2.0)])
        XCTAssertFalse(m.isListening)
    }

    func testAccidentalTapIsCancelled() {
        var m = ChordStateMachine(chord: .controlOption)
        let events = run(&m, [.modifiersChanged(co, at: 1.0), .modifiersChanged([], at: 1.1)])
        XCTAssertEqual(events, [.began(at: 1.0), .cancelled(reason: .tooShort)])
    }

    func testOtherKeyCancelsAndRequiresFullRelease() {
        var m = ChordStateMachine(chord: .controlOption)
        let events = run(&m, [
            .modifiersChanged(co, at: 0),
            .keyDown(at: 0.3),                       // e.g. Control-Option-Right Arrow
            .modifiersChanged([.control], at: 0.5),
            .modifiersChanged(co, at: 0.6),          // still part of the same gesture: no new turn
            .modifiersChanged([], at: 0.8),
            .modifiersChanged(co, at: 1.0),          // fresh press after full release: new turn
        ])
        XCTAssertEqual(events, [.began(at: 0), .cancelled(reason: .otherKeyPressed), .began(at: 1.0)])
    }

    func testExtraModifierCancels() {
        var m = ChordStateMachine(chord: .controlOption)
        let events = run(&m, [
            .modifiersChanged(co, at: 0),
            .modifiersChanged([.control, .option, .command], at: 0.4),
            .modifiersChanged(co, at: 0.5),
            .modifiersChanged([], at: 0.9),
        ])
        XCTAssertEqual(events, [.began(at: 0), .cancelled(reason: .extraModifier)])
    }

    func testSupersetPressedFirstDoesNotTrigger() {
        var m = ChordStateMachine(chord: .controlOption)
        let events = run(&m, [
            .modifiersChanged([.control, .option, .shift], at: 0),
            .modifiersChanged([], at: 1),
        ])
        XCTAssertEqual(events, [])
    }

    func testInterruptionCancels() {
        var m = ChordStateMachine(chord: .controlOption)
        let events = run(&m, [.modifiersChanged(co, at: 0), .interrupted(at: 1)])
        XCTAssertEqual(events, [.began(at: 0), .cancelled(reason: .interrupted)])
        // After an interruption the next real press works.
        XCTAssertEqual(m.handle(.modifiersChanged(co, at: 2)), .began(at: 2))
    }

    func testMaximumHoldTick() {
        var m = ChordStateMachine(chord: .controlOption)
        m.maximumHold = 10
        _ = m.handle(.modifiersChanged(co, at: 0))
        XCTAssertNil(m.tick(now: 5))
        XCTAssertEqual(m.tick(now: 11), .cancelled(reason: .tooLong))
        XCTAssertNil(m.handle(.modifiersChanged([], at: 12)))
    }

    func testToggleModeStartsAndStopsOnCleanTaps() {
        var m = ChordStateMachine(chord: Chord(modifiers: co, mode: .toggle))
        let events = run(&m, [
            .modifiersChanged(co, at: 0.0), .modifiersChanged([], at: 0.2),   // tap: start
            .modifiersChanged(co, at: 3.0), .modifiersChanged([], at: 3.2),   // tap: stop
        ])
        XCTAssertEqual(events, [.began(at: 0.2), .ended(at: 3.2, heldFor: 3.0)])
    }

    func testToggleModeIgnoresSlowPressAndShortcuts() {
        var m = ChordStateMachine(chord: Chord(modifiers: co, mode: .toggle))
        let events = run(&m, [
            .modifiersChanged(co, at: 0.0), .modifiersChanged([], at: 1.5),    // too slow: ignored
            .modifiersChanged(co, at: 2.0), .keyDown(at: 2.1), .modifiersChanged([], at: 2.2), // shortcut: ignored
        ])
        XCTAssertEqual(events, [])
        XCTAssertFalse(m.isListening)
    }

    func testToggleModeKeepsListeningThroughAnAbortedStopTap() {
        var m = ChordStateMachine(chord: Chord(modifiers: co, mode: .toggle))
        let events = run(&m, [
            .modifiersChanged(co, at: 0.0), .modifiersChanged([], at: 0.1),   // start
            .modifiersChanged(co, at: 2.0), .keyDown(at: 2.05),              // part of another shortcut
            .modifiersChanged([], at: 2.1),
        ])
        XCTAssertEqual(events, [.began(at: 0.1)])
        XCTAssertTrue(m.isListening)
    }

    func testFunctionControlChord() {
        var m = ChordStateMachine(chord: Chord(modifiers: [.function, .control]))
        let events = run(&m, [
            .modifiersChanged([.function], at: 0), .modifiersChanged([.function, .control], at: 0.1),
            .modifiersChanged([], at: 1.1),
        ])
        XCTAssertEqual(events, [.began(at: 0.1), .ended(at: 1.1, heldFor: 1.0)])
    }

    func testResetForgetsAHoldInProgress() {
        var m = ChordStateMachine(chord: .controlOption)
        _ = m.handle(.modifiersChanged(co, at: 0))
        m.reset()
        XCTAssertFalse(m.isListening)
        XCTAssertNil(m.handle(.modifiersChanged([], at: 1)), "no stale end after reset")
    }
}
