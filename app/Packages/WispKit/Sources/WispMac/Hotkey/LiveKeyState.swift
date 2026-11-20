import Combine
import WispCore

/// Live view of the keyboard for UI: which modifiers are held and the latest chord event.
/// Fed by `HotkeyMonitor`; used by the shortcut test (onboarding) and the shortcut recorder (settings).
@MainActor
public final class LiveKeyState: ObservableObject {
    @Published public private(set) var held: ModifierSet = []
    @Published public private(set) var lastEvent: ChordEvent?
    /// True between `.began` and `.ended`/`.cancelled`.
    @Published public private(set) var chordActive = false
    /// Successful practice holds since the test view appeared.
    @Published public var successfulHolds = 0
    /// Set while the onboarding shortcut test is visible: holds show the companion and level meter but
    /// nothing is sent anywhere.
    @Published public var isPracticing = false
    /// True while recording a new shortcut; chord events are ignored entirely.
    public var isRecordingShortcut: Bool { recorder != nil }
    /// While set, the next modifier combination of two or more keys is reported here (shortcut recording).
    public var recorder: ((ModifierSet) -> Void)?
    private var recordingPeak: ModifierSet = []

    public init() {}

    func modifiersChanged(_ mods: ModifierSet) {
        held = mods
        guard let recorder else { return }
        // Record the largest combination held; commit when everything is released. Fn is never part of a
        // shortcut (see `Chord.isValid`), so it is ignored here.
        let mods = mods.subtracting(.function)
        if mods.count > recordingPeak.count { recordingPeak = mods }
        if mods.isEmpty && recordingPeak.count >= 2 {
            let chosen = recordingPeak
            recordingPeak = []
            self.recorder = nil
            recorder(chosen)
        } else if mods.isEmpty {
            recordingPeak = []
        }
    }

    func chordEvent(_ event: ChordEvent) {
        lastEvent = event
        switch event {
        case .began: chordActive = true
        case .ended: chordActive = false; successfulHolds += 1
        case .cancelled: chordActive = false
        }
    }

    public func cancelRecording() {
        recorder = nil
        recordingPeak = []
    }
}
