import XCTest
@testable import WispCore

final class PermissionModelTests: XCTestCase {
    func testMissingOrderAndReadiness() {
        let snap = PermissionSnapshot(states: [.microphone: .granted, .inputMonitoring: .denied, .screenRecording: .notDetermined])
        XCTAssertEqual(snap.missing, [.inputMonitoring, .screenRecording])
        XCTAssertEqual(Readiness(snap), .needsAttention([.inputMonitoring, .screenRecording]))
        let all = PermissionSnapshot(states: [.microphone: .granted, .inputMonitoring: .granted, .screenRecording: .granted])
        XCTAssertEqual(Readiness(all), .ready)
    }

    func testRevocationDetection() {
        let before = PermissionSnapshot(states: [.microphone: .granted, .inputMonitoring: .granted, .screenRecording: .granted])
        let after = PermissionSnapshot(states: [.microphone: .granted, .inputMonitoring: .granted, .screenRecording: .denied])
        XCTAssertEqual(after.revoked(since: before), [.screenRecording])
        XCTAssertEqual(before.revoked(since: after), [])
    }

    func testCardForGrantedIsNil() {
        XCTAssertNil(RecoveryCard.make(kind: .microphone, state: .granted, chord: .controlOption, wasPreviouslyGranted: true))
    }

    func testNotDeterminedOffersSystemPrompt() throws {
        let card = try XCTUnwrap(RecoveryCard.make(kind: .microphone, state: .notDetermined, chord: .controlOption, wasPreviouslyGranted: false))
        XCTAssertEqual(card.primary, .requestAccess(.microphone))
        XCTAssertNil(card.secondary)
    }

    func testDeniedOpensSettingsAndOffersRelaunchForScreen() throws {
        let card = try XCTUnwrap(RecoveryCard.make(kind: .screenRecording, state: .denied, chord: .controlOption, wasPreviouslyGranted: false))
        XCTAssertEqual(card.primary, .openSettings(.screenRecording))
        XCTAssertEqual(card.secondary, .relaunch)
    }

    func testRevokedScreenCardMentionsPeriodicConfirmation() throws {
        let card = try XCTUnwrap(RecoveryCard.make(kind: .screenRecording, state: .denied, chord: .controlOption, wasPreviouslyGranted: true))
        XCTAssertTrue(card.message.contains("every so often"))
        XCTAssertTrue(card.title.contains("can't see"))
    }

    func testCardUsesTheUsersChordNotAHardcodedOne() throws {
        let chord = Chord(modifiers: [.option, .command])
        let card = try XCTUnwrap(RecoveryCard.make(kind: .microphone, state: .notDetermined, chord: chord, wasPreviouslyGranted: false))
        XCTAssertTrue(card.message.contains("Option + Command"))
        XCTAssertFalse(card.message.contains("Control"))
    }

    func testNeedsRelaunchAndRestricted() throws {
        XCTAssertEqual(RecoveryCard.make(kind: .inputMonitoring, state: .needsRelaunch, chord: .controlOption, wasPreviouslyGranted: false)?.primary, .relaunch)
        XCTAssertEqual(RecoveryCard.make(kind: .screenRecording, state: .restricted, chord: .controlOption, wasPreviouslyGranted: false)?.primary, .openSettings(.screenRecording))
    }

    func testSettingsURLs() {
        XCTAssertEqual(PermissionKind.inputMonitoring.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }
}

final class ChordTests: XCTestCase {
    func testVoiceOverConflictAndDefaults() {
        XCTAssertTrue(Chord.controlOption.conflictsWithVoiceOver)
        XCTAssertFalse(Chord.optionCommand.conflictsWithVoiceOver)
        XCTAssertEqual(Chord.recommendedDefault(voiceOverRunning: true), .optionCommand)
        XCTAssertEqual(Chord.recommendedDefault(voiceOverRunning: false), .controlOption)
    }

    func testValidityAndNames() {
        XCTAssertFalse(Chord(modifiers: [.command]).isValid)
        XCTAssertFalse(Chord(modifiers: [.function, .control]).isValid, "Fn chords are not allowed")
        XCTAssertTrue(Chord(modifiers: [.control, .shift]).isValid)
        XCTAssertEqual(Chord(modifiers: [.command, .control, .function]).modifiers.symbolList, ["fn", "⌃", "⌘"])
        XCTAssertEqual(Chord.controlOption.displayName, "Control + Option")
    }

    func testCodableRoundTrip() throws {
        let chord = Chord(modifiers: [.control, .shift], mode: .toggle)
        let data = try JSONEncoder().encode(chord)
        XCTAssertEqual(try JSONDecoder().decode(Chord.self, from: data), chord)
    }
}

final class PolicyGateTests: XCTestCase {
    func testContentBlockedUntilDisclosureAccepted() {
        let gate = ConsentPolicyGate(disclosureAccepted: { false })
        XCTAssertNotEqual(gate.evaluate(NetworkIntent(purpose: .visionRequest, host: "integrate.api.nvidia.com", carriesUserContent: true)), .allow)
        XCTAssertEqual(gate.evaluate(NetworkIntent(purpose: .modelDownload, host: "huggingface.co", carriesUserContent: false)), .allow)
        let accepted = ConsentPolicyGate(disclosureAccepted: { true })
        XCTAssertEqual(accepted.evaluate(NetworkIntent(purpose: .visionRequest, host: "integrate.api.nvidia.com", carriesUserContent: true)), .allow)
    }

    func testEmptyContextProvider() async {
        let snippets = await EmptyContextProvider().context(for: ContextRequest(transcript: "x", frontmostBundleID: nil))
        XCTAssertTrue(snippets.isEmpty)
    }
}
