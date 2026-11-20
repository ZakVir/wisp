import AppKit
import WispCore

/// Everything known about one push-to-talk turn when the user lets go.
public struct TurnInput: Sendable {
    public var id: UUID
    public var keyDownUptime: TimeInterval
    public var keyUpUptime: TimeInterval
    public var utterance: Utterance
    /// Set for a typed question (no recording to transcribe).
    public var typedQuestion: String? = nil
    /// Step-by-step guidance context for a follow-up step.
    public var guideText: String? = nil
    /// Answer without sound this time (captions and the card).
    public var silent = false
}

/// Runs one push-to-talk turn: chord down → listen → chord up → hand the recording on.
/// Later stages (screenshot, speech-to-text, vision, speech) plug in through the callbacks.
@MainActor
public final class TurnCoordinator {
    public enum Phase: Equatable { case idle, listening, processing }

    public private(set) var phase: Phase = .idle
    public let hotkey: HotkeyMonitor
    public let recorder = AudioRecorder()
    public let earcons = EarconPlayer()
    private let app: AppState
    private let overlay: OverlayController
    private let recovery: RecoveryCardController
    private var currentTurnID = UUID()
    private var recording: AudioRecorder.Token?
    private var keyDownUptime: TimeInterval = 0
    private var processingTask: Task<Void, Never>?
    private var beganNotified = false

    /// Called the instant listening starts (start streaming speech-to-text here so no audio is missed).
    /// Key-down of a new hold: turn id and the key event's uptime.
    public var onListeningStarted: ((UUID, TimeInterval) -> Void)?
    /// Called once a hold has lasted past the accidental-tap threshold (capture the screenshot here).
    /// Not called for accidental taps, so they never capture the screen.
    public var onTurnBegan: ((UUID, TimeInterval) -> Void)?
    /// Called with each 16 kHz chunk while listening (on the audio queue).
    public var onAudioChunk: (@Sendable ([Float]) -> Void)? {
        didSet { recorder.onChunk = onAudioChunk }
    }
    /// Called whenever a turn is abandoned or superseded; later stages drop their work for it.
    public var onTurnCancelled: ((UUID) -> Void)?
    /// A new hold that can't start a turn (microphone off) still interrupts the previous answer.
    public var onInterrupt: (() -> Void)?

    /// Ends the current turn wherever it is (listening, thinking or speaking): the menu's Stop.
    public func stopCurrentTurn() {
        guard phase != .idle else { return }
        abandonCurrentTurn()
        overlay.setMode(.hidden)
        earcons.idle()
    }

    // MARK: Typed questions

    /// Called when a typed question starts (take the screenshot now, before the question box shows).
    public var onTypedTurnStarted: ((UUID) -> Void)?

    /// Starts a typed question; returns its id. Any answer in progress stops.
    public func beginTypedTurn() -> UUID {
        if phase != .idle { abandonCurrentTurn() }
        onInterrupt?()
        currentTurnID = UUID()
        keyDownUptime = ProcessInfo.processInfo.systemUptime
        onTypedTurnStarted?(currentTurnID)
        return currentTurnID
    }

    /// The question was typed and sent.
    public func submitTypedTurn(_ id: UUID, question: String, guideText: String? = nil, silent: Bool = false) {
        guard id == currentTurnID, phase == .idle else { return }
        phase = .processing
        overlay.setMode(.thinking)
        let keyDown = keyDownUptime
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let input = TurnInput(id: id, keyDownUptime: keyDown, keyUpUptime: now,
                                  utterance: Utterance(samples: [], sampleRate: 16_000, firstBufferLatency: nil, peakDBFS: -120),
                                  typedQuestion: question, guideText: guideText, silent: silent)
            await self.process?(input)
            self.endTurn(id)
        }
    }

    /// The question box was closed without asking: drop the screenshot.
    public func cancelTypedTurn(_ id: UUID) {
        guard id == currentTurnID, phase == .idle else { return }
        onTurnCancelled?(id)
    }

    /// While paused, the shortcut starts nothing (a held chord shows `onPausedPress` instead).
    public var isPaused = false
    public var onPausedPress: (() -> Void)?

    /// A short caption for problems found here (microphone), shown without speaking.
    public var onNotice: ((String) -> Void)?
    /// Processes a finished recording. Return when the turn (answer, speech) is fully done.
    public var process: ((TurnInput) async -> Void)?

    public init(app: AppState, overlay: OverlayController, recovery: RecoveryCardController) {
        self.app = app
        self.overlay = overlay
        self.recovery = recovery
        hotkey = HotkeyMonitor(chord: app.effectiveChord)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["WISP_FAKE_MIC_FILE"] {
            recorder.source = .file(URL(fileURLWithPath: path))
        }
        #endif
        hotkey.onEvent = { [weak self] event in
            guard let self else { return }
            self.app.keys.chordEvent(event)
            // While recording a new shortcut, the old chord must not start a turn.
            guard !self.app.keys.isRecordingShortcut else { return }
            self.handle(event)
        }
        hotkey.onModifiersChanged = { [weak app] mods in app?.keys.modifiersChanged(mods) }
        recorder.onLevel = { [weak self] level in self?.overlay.setLevel(level) }
        recorder.onFirstBuffer = { [weak self] token in
            guard let self, token == self.recording, self.phase == .listening else { return }
            self.earcons.play(.listening)
        }
        recorder.onError = { [weak self] token, error in
            guard let self, token == self.recording else { return }
            self.recorderFailed(error)
        }
        earcons.enabled = app.config.speech.earcons
        recorder.chosenInputUID = app.config.speech.inputDeviceUID
        app.permissions.inputMonitoringProbe = { HotkeyMonitor.canCreateTap() }
        hotkey.setDoubleTapKey(app.config.typeKeyModifier)
        hotkey.setDoubleTapEnabled(app.config.typeToAsk && app.effectiveChord.modifiers != app.config.typeKeyModifier)
        recorder.prepare()
    }

    /// Starts watching for the chord (when Input Monitoring allows it). Safe to call repeatedly.
    public func startIfPossible() {
        recorder.prepare()
        if hotkey.status == .running { return }
        if !hotkey.start() {
            Log.hotkey.notice("hotkey unavailable until Input Monitoring is granted")
        }
    }

    /// Call after settings or VoiceOver state change. Only an actual chord change touches the hotkey.
    public func configurationChanged() {
        hotkey.update(chord: app.effectiveChord)
        hotkey.setDoubleTapKey(app.config.typeKeyModifier)
        hotkey.setDoubleTapEnabled(app.config.typeToAsk && app.effectiveChord.modifiers != app.config.typeKeyModifier)
        earcons.enabled = app.config.speech.earcons
        recorder.chosenInputUID = app.config.speech.inputDeviceUID
    }

    // MARK: - Chord events

    private func handle(_ event: ChordEvent) {
        if isPaused {
            if case .began = event { onPausedPress?() }
            return
        }
        switch event {
        case .began(let at): begin(at: at)
        case .ended(let at, _): finish(at: at)
        case .cancelled(let reason): cancel(reason: reason)
        }
    }

    private func begin(at uptime: TimeInterval) {
        // A new hold always wins: abandon whatever the previous turn was doing (barge-in).
        if phase != .idle { abandonCurrentTurn() }

        // Cached state only: the hot path must not probe permissions.
        if recorder.source == .microphone && app.permissions.snapshot[.microphone] == .denied {
            onInterrupt?() // the previous answer must still stop
            overlay.setMode(.hidden)
            recovery.show(for: [.microphone])
            return
        }
        currentTurnID = UUID()
        keyDownUptime = uptime
        beganNotified = false
        phase = .listening
        overlay.setMode(.listening)
        onListeningStarted?(currentTurnID, uptime)
        recording = recorder.start(at: uptime)

        // Hand the turn to later stages once it is clearly not an accidental tap.
        let turn = currentTurnID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.currentTurnID == turn, self.phase != .idle, !self.beganNotified else { return }
            self.beganNotified = true
            self.onTurnBegan?(turn, uptime)
        }
    }

    private func finish(at uptime: TimeInterval) {
        guard phase == .listening, let token = recording else { return }
        phase = .processing
        overlay.setMode(.thinking)
        let turn = currentTurnID
        let keyDown = keyDownUptime
        if !beganNotified {
            // Released between 250 ms (minimum hold) and the deferred notification: notify now.
            beganNotified = true
            onTurnBegan?(turn, keyDown)
        }
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let utterance = await self.recorder.stop(token)
            guard self.currentTurnID == turn, !Task.isCancelled else { return }
            guard let utterance else {
                self.onTurnCancelled?(turn)
                self.endTurn(turn)
                return
            }
            if utterance.isSilent {
                Log.audio.notice("turn discarded: silent recording (\(String(format: "%.2f", utterance.duration), privacy: .public) s)")
                self.earcons.play(.problem)
                self.onNotice?("I didn't hear anything. Is the right microphone selected in Settings?")
                self.onTurnCancelled?(turn)
                self.endTurn(turn)
                return
            }
            self.earcons.play(.done)
            Log.audio.info("turn audio: \(String(format: "%.2f", utterance.duration), privacy: .public) s, first buffer \(Int((utterance.firstBufferLatency ?? -1) * 1000), privacy: .public) ms, peak \(Int(utterance.peakDBFS), privacy: .public) dBFS")
            let input = TurnInput(id: turn, keyDownUptime: keyDown, keyUpUptime: uptime, utterance: utterance)
            // Practice holds (onboarding) prove the shortcut and mic work; nothing is sent anywhere.
            if let process = self.process, !self.app.keys.isPracticing {
                await process(input)
            } else {
                // Practice hold: close the speech stream and drop the screenshot (nothing is sent anywhere).
                self.onTurnCancelled?(turn)
            }
            self.endTurn(turn)
        }
    }

    private func cancel(reason: CancelReason) {
        Log.hotkey.info("turn cancelled: \(reason.rawValue, privacy: .public)")
        guard phase == .listening else { return }
        abandonCurrentTurn()
        overlay.setMode(.hidden)
        earcons.idle()
    }

    /// Stops recording/processing for the current turn and tells later stages to drop it.
    private func abandonCurrentTurn() {
        processingTask?.cancel()
        processingTask = nil
        if let recording { recorder.cancel(recording) }
        recording = nil
        onTurnCancelled?(currentTurnID)
        phase = .idle
    }

    private func endTurn(_ turn: UUID) {
        guard turn == currentTurnID else { return }
        phase = .idle
        recording = nil
        overlay.setMode(.hidden)
        earcons.idle()
    }

    private func recorderFailed(_ error: AudioRecorder.RecorderError) {
        earcons.play(.problem)
        if error == .permissionDenied {
            recovery.show(for: [.microphone])
        } else {
            onNotice?("I couldn't hear your microphone. Check it in Wisp Settings, under General.")
        }
        onTurnCancelled?(currentTurnID)
        endTurn(currentTurnID)
    }
}
