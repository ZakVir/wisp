import AppKit
import CoreServices
import WispCore

/// The stages after key-down: screenshot, streaming speech-to-text, vision model, spoken answer and pointing.
@MainActor
public final class TurnPipeline {
    public let capturer = ScreenCapturer()
    public let stt = MoonshineSpeechToText()
    public let systemVoice = SystemSpeechEngine()
    /// The on-device voice once installed (M5); falls back to the system voice.
    public var neuralVoice: TextToSpeechEngine?
    /// Called with each answer event for drawing (pointing, circles…), already mapped to the screen.
    public var onVisual: ((AssistantEvent, CaptureRecord, ModelCoordinateSpace) -> Void)?
    /// Captions: a sentence started being spoken (index, text), or the answer ended (nil).
    public var onCaption: ((String?) -> Void)?
    /// Every finished turn's timing (content-free).
    public var onTiming: ((TurnTiming) -> Void)?
    /// Shows the front app's keyboard shortcuts (app name, its process, the shortcuts).
    public var onShowShortcuts: ((String, pid_t, [UIContext.MenuItem]) -> Void)?
    /// Opens an app / does one menu command; returns what to say.
    public var onAppAction: ((AppAction) async -> String)?
    /// Does a browser action (search, open a site); returns what to say.
    public var onWebAction: ((WebAction) async -> String)?
    /// A sketch is starting (fix where it goes), and each stroke as it arrives (points in a 100 × 100 box, y down).
    public var onSketchBegin: (() -> Void)?
    public var onSketchStroke: (([Vec2]) -> Void)?
    /// Draws a built-in shape with the companion, around the pointer.
    public var onDraw: ((Drawing.Shape) -> Void)?
    /// Shows the magnifier around the pointer; false if the screen couldn't be read.
    public var onMagnify: (() async -> Bool)?
    /// No network connection right now.
    public var isOffline: (() -> Bool)?
    /// A notes request; returns what to say back.
    public var onNotesCommand: ((Notes.Command) -> String)?
    /// A timer or reminder request; returns what to say back.
    public var onTimerCommand: ((TimerCommand) -> String)?
    /// A quiet answer starts (true: mute the voice, force captions) or ends (false: restore).
    public var onQuietAnswer: ((Bool) -> Void)?
    /// A quiet answer finished: show it in the answer card.
    public var onQuietResult: ((String, String) -> Void)?
    /// Writing help finished: the request and the new text (shown in the answer card).
    public var onWritingResult: ((String, String) -> Void)?
    /// Speech settings were changed by a voice command (apply them before the confirmation is spoken).
    public var onVoiceSettingsChanged: (() -> Void)?
    /// The answer History has about a topic, for "what did you tell me about…".
    public var onRecall: ((String) -> String?)?
    /// The last question asked, for "try again".
    public var lastQuestion: (() -> String?)?
    /// The last answer's sentences, for "say that again".
    public var lastAnswer: (() -> [String]?)?
    /// A question was answered (its words and the spoken sentences), for Recent Answers.
    public var onAnswered: ((String, [String]) -> Void)?
    /// During a walkthrough: whether a next-step reply pointing here (AppKit global) at this label just repeats the
    /// step they already did. Such a reply isn't spoken (`onGuideRepeat` runs instead).
    public var isGuideRepeat: ((Vec2?, String) -> Bool)?
    public var onGuideRepeat: (() -> Void)?
    /// During a walkthrough, the next-step request for a question that means "go on" ("what now?"), else nil.
    public var guideTextForQuestion: ((String) -> String?)?
    /// Right before `onAnswered` for a model answer: the reply's STEPS line (true: more steps follow; nil: none given).
    public var onStepsStatus: ((Bool?) -> Void)?
    /// User-facing problems (spoken and captioned).
    public var onProblem: ((String) -> Void)?

    private let app: AppState
    private let context: ContextProvider
    private var captures: [UUID: Task<[CapturedScreen], Error>] = [:]
    private var timings: [UUID: TurnTiming] = [:]
    private var sttTurn: UUID?
    private var speaking: TextToSpeechEngine?
    private var frontmostName: [UUID: String] = [:]
    private var frontmostPID: [UUID: pid_t] = [:]
    /// The unread rest of a long page ("keep reading").
    private var readingRest: String?
    /// The front app's controls and menus, read when the hold starts (needs the optional Accessibility permission).
    private var uiReads: [UUID: Task<UIContext?, Never>] = [:]
    /// The newest turn; an older turn still finishing must never speak, draw or remember anything.
    private var currentTurn: UUID?

    public init(app: AppState, context: ContextProvider = EmptyContextProvider()) {
        self.app = app
        self.context = context
        capturer.longEdge = app.config.vision.imageLongEdge
        prewarmIfAllowed()
    }

    /// Pre-fetches the display list, but only once Screen Recording is granted: asking ScreenCaptureKit for
    /// content without permission makes macOS show its prompt, which must only happen at the onboarding step.
    public func prewarmIfAllowed() {
        guard CGPreflightScreenCaptureAccess() else { return }
        let capturer = self.capturer
        Task { await capturer.prewarm() }
    }

    /// Feeds microphone audio (16 kHz mono) to speech-to-text. Called on the audio queue.
    public nonisolated func audioChunk(_ samples: [Float]) {
        stt.append(samples)
    }

    // MARK: Turn lifecycle

    /// Key-down: barge-in (stop speaking) and start streaming speech-to-text immediately.
    public func listeningStarted(_ id: UUID, keyDownAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let interrupted = speaking
        stopSpeaking()
        currentTurn = id
        var timing = TurnTiming(keyDown: keyDownAt)
        if let interrupted {
            let stopped = ProcessInfo.processInfo.systemUptime + interrupted.outputLatency
            timing.bargeInStop = TurnTiming.ms(keyDownAt, stopped)
        }
        timings[id] = timing
        frontmostName[id] = NSWorkspace.shared.frontmostApplication?.localizedName
        frontmostPID[id] = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if stt.isReady {
            do {
                try stt.begin(keyterms: keyterms())
                sttTurn = id
            } catch {
                Log.speech.error("stt begin failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A typed question is starting: stop any answer, and take the screenshot and read the app now, before the
    /// question box appears (Wisp's own windows are never in the screenshot anyway).
    public func typedTurnStarted(_ id: UUID) {
        stopSpeaking()
        currentTurn = id
        timings[id] = TurnTiming(keyDown: ProcessInfo.processInfo.systemUptime)
        frontmostName[id] = NSWorkspace.shared.frontmostApplication?.localizedName
        frontmostPID[id] = NSWorkspace.shared.frontmostApplication?.processIdentifier
        app.permissions.refresh()
        startCapture(id)
        startUIRead(id)
    }

    /// Hold confirmed (not an accidental tap): re-check permissions (they can change at any time, and this is off
    /// the key-down hot path) and take the screenshot. Not at key-down: taps and other Control+Option shortcuts
    /// would flash macOS's screen-recording indicator, and the capture finishes during the hold either way.
    public func turnBegan(_ id: UUID, at uptime: TimeInterval) {
        app.permissions.refresh()
        if captures[id] == nil { startCapture(id) }
        if uiReads[id] == nil { startUIRead(id) }
        if neuralVoice?.isReady == true { neuralVoice?.prewarm() }
    }

    /// Reads the front app's controls and menu commands, alongside the screenshot. Skipped without the permission
    /// or when the setting is off, and never for Wisp's own windows.
    private func startUIRead(_ id: UUID) {
        guard app.config.vision.readAppControls, UIContextReader.isAllowed,
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.config.privacy.privateApps.contains(front.bundleIdentifier ?? "") else { return }
        let pid = front.processIdentifier
        let name = front.localizedName ?? "the app"
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let mouse = NSEvent.mouseLocation
        let pointer = CGPoint(x: mouse.x, y: primaryHeight - mouse.y) // Accessibility uses a top-left origin
        let privateApps = Set(app.config.privacy.privateApps)
        uiReads[id] = Task.detached(priority: .userInitiated) {
            UIContextReader.read(pid: pid, appName: name, primaryHeight: primaryHeight, pointer: pointer, privateApps: privateApps)
        }
    }

    /// Takes the screenshot of what the user is looking at. It stays in memory and is dropped if the turn is
    /// cancelled or is a practice hold (`turnCancelled`).
    private func startCapture(_ id: UUID) {
        guard app.permissions.snapshot[.screenRecording].isUsable else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let capturer = self.capturer
        capturer.hiddenBundleIDs = Set(app.config.privacy.privateApps)
        let all = app.config.vision.captureAllDisplays && NSScreen.screens.count > 1
        captures[id] = Task.detached(priority: .userInitiated) {
            all ? try await capturer.captureAllDisplays(frontmostBundleID: frontmost)
                : [try await capturer.captureDisplay(frontmostBundleID: frontmost)]
        }
    }

    public func turnCancelled(_ id: UUID) {
        if currentTurn == id { currentTurn = nil }
        captures.removeValue(forKey: id)?.cancel()
        uiReads.removeValue(forKey: id)?.cancel()
        timings.removeValue(forKey: id)
        frontmostName.removeValue(forKey: id)
        frontmostPID.removeValue(forKey: id)
        if sttTurn == id {
            stt.cancel()
            sttTurn = nil
        }
    }

    /// Stops any answer in progress (new hold, Escape).
    /// True while an answer is being spoken.
    public var isSpeaking: Bool { speaking != nil }

    public func stopSpeaking() {
        if speaking != nil { Log.speech.info("barge-in: speech stopped") }
        speaking?.stop()
        speaking = nil
        onCaption?(nil)
    }

    /// Key-up with audio: transcript → vision model → spoken answer + pointing.
    public func process(_ input: TurnInput) async {
        var timing = timings.removeValue(forKey: input.id) ?? TurnTiming(keyDown: input.keyDownUptime)
        timing.keyDown = input.keyDownUptime
        timing.keyUp = input.keyUpUptime
        let turnID = input.id
        defer {
            // Never keep a screenshot (or anything else) for a turn after it ends, whatever path it took.
            captures.removeValue(forKey: turnID)?.cancel()
            frontmostName.removeValue(forKey: turnID)
            frontmostPID.removeValue(forKey: turnID)
            if isCurrent(turnID) { onTiming?(timing) } else { timing.outcome = "superseded"; onTiming?(timing) }
        }

        // 1. Words (typed, or recognised from the recording).
        var question: String
        if let typed = input.typedQuestion {
            question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            timing.sttFinal = ProcessInfo.processInfo.systemUptime
        } else {
            guard sttTurn == input.id else {
                timing.outcome = "stt_not_ready"
                await say([speechProblem?() ?? "My speech model is still getting ready. Try again in a moment."], timing: &timing)
                return
            }
            sttTurn = nil
            do {
                // A stalled recognizer must not leave the turn hanging.
                guard let transcript = try await withTimeout(seconds: 10, { try await self.stt.finish() }) else {
                    throw SpeechToTextError.failed("timed out")
                }
                guard isCurrent(turnID) else { return }
                question = transcript.text
                timing.sttFinal = ProcessInfo.processInfo.systemUptime
                Log.speech.info("stt final in \(Int(transcript.finalizeLatency * 1000), privacy: .public) ms (\(question.split(separator: " ").count, privacy: .public) words)")
            } catch {
                timing.outcome = "stt_failed"
                Log.speech.error("stt finish failed: \(String(describing: error), privacy: .public)")
                guard isCurrent(turnID) else { return }
                await say(["Sorry, I didn't catch that."], timing: &timing)
                return
            }
        }
        // "Try again" / "that's not right": the last question, asked again with a fresh look and the other model.
        var secondOpinion = false
        if QuestionIntent.isRetry(question), let last = lastQuestion?() {
            question = last
            secondOpinion = true
            onStatusCaption?("Taking another look…")
        }

        // What Wisp heard, for a moment (so a mishearing is obvious). Typed questions don't need it.
        if input.typedQuestion == nil, app.config.speech.showHeard, !question.isEmpty {
            onStatusCaption?("“\(RecentAnswers.title(for: question, limit: 80))”")
        }
        guard question.split(separator: " ").count >= 1 else {
            // Nothing said (or nothing recognisable): a soft sound and a caption, never a spoken reply.
            timing.outcome = "empty_question"
            await notice(app.effectiveChord.mode == .hold ? "I didn't catch a question. Hold the shortcut while you speak."
                                                          : "I didn't catch a question. Press the shortcut, speak, then press it again.")
            return
        }

        // Writing help with text selected: the new version goes to the clipboard and the answer card.
        if WritingHelp.isRequest(question), let pid = frontmostPID[input.id], !isPrivate(pid), pid != ProcessInfo.processInfo.processIdentifier,
           let selection = await writingSource(pid: pid) {
            timing.outcome = "writing"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let result = await write(request: question, selection: selection)
            guard isCurrent(turnID) else { return }
            switch result {
            case .success(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                onWritingResult?(question, text)
                onAnswered?(question, [text])
                // A summary is meant to be heard; a rewrite or translation is meant to be pasted.
                if WritingHelp.isSummary(question), text.count <= 900 {
                    await readAloud(text.replacingOccurrences(of: #"(?m)^\s*[-•*]\s*"#, with: "", options: .regularExpression), timing: &timing)
                } else {
                    await readAloud("Done. It's on your clipboard, ready to paste.", timing: &timing)
                }
            case .failure(let error):
                await readAloud(error.userMessage, timing: &timing)
            }
            return
        }

        // "Draw a star": common shapes are drawn by the companion itself, around the pointer (no AI needed).
        if let shape = Drawing.shape(in: question), let draw = onDraw {
            timing.outcome = "draw"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            draw(shape)
            let name = shape == .check ? "check mark" : shape == .smiley ? "smiley face" : shape.rawValue
            await readAloud("Here's a \(name).", timing: &timing)
            return
        }

        // "Search online for …", "open YouTube": Wisp opens it in the browser, with the companion showing each step.
        if app.config.allowWebActions, let action = WebAction.parse(question), let act = onWebAction {
            timing.outcome = "web"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let result = await act(action)
            guard isCurrent(turnID) else { return }
            await readAloud(result, timing: &timing)
            return
        }

        // "Open Fusion", "open Notes and make a new note", "open a new tab": open the app and do at most one menu command.
        if app.config.allowWebActions, let action = AppAction.parse(question), let act = onAppAction {
            timing.outcome = "app"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let result = await act(action)
            guard isCurrent(turnID) else { return }
            await readAloud(result, timing: &timing)
            return
        }

        // "Draw a cat": the AI sketches it in a small box (no screenshot needed) and the companion draws each stroke as
        // it arrives, around the pointer.
        if Drawing.isFreeSketch(question), let begin = onSketchBegin, let stroke = onSketchStroke {
            timing.outcome = "sketch"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let subject = Drawing.subject(of: question)
            begin()
            onStatusCaption?("Drawing \(subject)…")
            let drawn = await sketch(subject) { points in stroke(points) }
            onStatusCaption?(nil)
            guard isCurrent(turnID) else { return }
            await readAloud(drawn > 0 ? "There's \(subject)." : "I couldn't draw that just now. Try again in a moment.", timing: &timing)
            return
        }

        // "Give me a closer look": the area around the pointer, enlarged (on this Mac).
        if QuestionIntent.isMagnify(question), let magnify = onMagnify {
            timing.outcome = "magnify"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let shown = await magnify()
            await readAloud(shown ? "Here's a closer look." : "I couldn't take a closer look just now.", timing: &timing)
            return
        }

        // "Define ephemeral": the dictionary built into macOS (instant, offline). Unknown words go to the AI.
        if let word = Definition.word(in: question),
           let entry = DCSCopyTextDefinition(nil, word as NSString, CFRangeMake(0, (word as NSString).length))?.takeRetainedValue() as String? {
            timing.outcome = "definition"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let spoken = Definition.spoken(word: word, entry: entry)
            onAnswered?(question, [spoken])
            onWritingResult?(question, String(entry.prefix(1500)))
            await readAloud(spoken, timing: &timing)
            return
        }

        // Plain arithmetic, unit conversions, the time and date: exact, instant, on this Mac.
        if let math = QuickMath.answer(question) ?? TimeAnswer.answer(question) ?? MacFacts.parse(question).map(MacFactsReader.answer)
            ?? LittleHelpers.answer(question) {
            timing.outcome = "math"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            onAnswered?(question, [math])
            await readAloud(math, timing: &timing)
            return
        }

        // Notes: "remember that…", "what did I ask you to remember?" (kept on this Mac, never sent anywhere).
        if let command = Notes.parse(question), let handle = onNotesCommand {
            timing.outcome = "notes"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            await readAloud(handle(command), timing: &timing)
            return
        }

        // Timers and reminders: kept by Wisp itself (no AI needed).
        if let command = TimerCommand.parse(question), let handle = onTimerCommand {
            timing.outcome = "timer"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            await readAloud(handle(command), timing: &timing)
            return
        }

        // "Talk faster", "be quiet": change how Wisp talks, right here.
        if let command = VoiceCommand.parse(question) {
            timing.outcome = command == .hush ? "hush" : "voice_command"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            if command == .hush { return } // the hold already stopped the answer; stay quiet
            app.update { config in
                config.speech.rate = command.rate(from: config.speech.rate)
                if command == .mute { config.speech.speakAnswers = false }
                if command == .unmute { config.speech.speakAnswers = true }
            }
            onVoiceSettingsChanged?()
            await readAloud(command.confirmation, timing: &timing)
            return
        }

        // "Copy the text on my screen": read on this Mac and put on the clipboard (no AI needed).
        if QuestionIntent.isCopyScreenText(question) {
            timing.outcome = "copy_text"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let lines = await copyScreenText()
            guard isCurrent(turnID) else { return }
            let message: String
            switch lines {
            case nil: message = "I couldn't read your screen just now."
            case 0?: message = "I didn't find any text on your screen."
            case let n?: message = "Copied the text on your screen, \(n) line\(n == 1 ? "" : "s"). Paste it anywhere."
            }
            await readAloud(message, timing: &timing)
            return
        }

        // "What are the shortcuts here?": the front app's own list, straight from its menus (no AI needed).
        if QuestionIntent.isShortcutList(question), UIContextReader.isAllowed, let pid = frontmostPID[input.id], !isPrivate(pid),
           pid != ProcessInfo.processInfo.processIdentifier {
            timing.outcome = "shortcuts"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let items = await Task.detached(priority: .userInitiated, operation: { UIContextReader.menuShortcuts(pid: pid) }).value
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "This app"
            guard isCurrent(turnID) else { return }
            onShowShortcuts?(name, pid, items)
            await readAloud(items.isEmpty ? "\(name) doesn't list any keyboard shortcuts in its menus." : "Here are \(name)'s keyboard shortcuts.", timing: &timing)
            return
        }

        // "Say that again": the last answer, word for word (no need to ask the AI again).
        if QuestionIntent.isRepeat(question), let last = lastAnswer?(), !last.isEmpty {
            timing.outcome = "repeat"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            await readAloud(last.joined(separator: " "), timing: &timing)
            return
        }

        // "What can you do?": the abilities this version really has.
        if QuestionIntent.asksCapabilities(question) {
            timing.outcome = "repeat"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            onWritingResult?("What Wisp can do", QuestionIntent.capabilitiesCard)
            await readAloud(QuestionIntent.capabilitiesSpoken, timing: &timing)
            return
        }

        // "What did you tell me about cropping earlier?": the answer from History.
        if let topic = History.recallTopic(question), let recall = onRecall {
            timing.outcome = "repeat"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            await readAloud(recall(topic) ?? "I don't have anything about that in History.", timing: &timing)
            return
        }

        // "Keep reading": the next part of a long page.
        if QuestionIntent.isKeepReading(question), let remaining = readingRest {
            timing.outcome = "read_page"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let (part, rest) = QuestionIntent.readingChunk(remaining)
            readingRest = rest
            await readAloud(rest == nil ? part : part + " Say “keep reading” for more.", timing: &timing)
            return
        }

        // "Read what I copied": the clipboard's text, read on this Mac.
        if QuestionIntent.isReadClipboard(question) {
            timing.outcome = "read_aloud"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await readAloud(text.isEmpty ? "There's no text on your clipboard." : String(text.prefix(8000)), timing: &timing)
            return
        }

        // "Read this to me" with text selected: read it word for word in Wisp's voice, on this Mac (no AI needed).
        if QuestionIntent.isReadAloud(question), let pid = frontmostPID[input.id], !isPrivate(pid),
           let text = await Task.detached(priority: .userInitiated, operation: { UIContextReader.fullSelection(pid: pid, limit: 60_000) }).value {
            timing.outcome = "read_aloud"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            let (part, rest) = QuestionIntent.readingChunk(text)
            readingRest = rest
            await readAloud(rest == nil ? part : part + " Say “keep reading” for more.", timing: &timing)
            return
        }
        // Nothing selected ("read this to me"), or "read this page to me": the front window's text, read on this Mac.
        if QuestionIntent.isReadAloud(question) || QuestionIntent.isReadPage(question), let pid = frontmostPID[input.id], !isPrivate(pid),
           pid != ProcessInfo.processInfo.processIdentifier {
            timing.outcome = "read_page"
            captures.removeValue(forKey: input.id)?.cancel()
            uiReads.removeValue(forKey: input.id)?.cancel()
            onStatusCaption?("Reading the page…")
            let text = await windowText(pid: pid)
            onStatusCaption?(nil)
            guard isCurrent(turnID) else { return }
            guard let text else {
                await readAloud("I couldn't find any text to read in that window.", timing: &timing)
                return
            }
            let (part, rest) = QuestionIntent.readingChunk(text)
            readingRest = rest
            await readAloud(rest == nil ? part : part + " Say “keep reading” for more.", timing: &timing)
            return
        }

        // 2. Screenshot (taken during the hold; usually long done).
        guard let captureTask = captures.removeValue(forKey: input.id) else {
            timing.outcome = "no_screenshot"
            onNeedsPermission?(.screenRecording)
            await say(["I can't see your screen yet. Turn on Screen Recording for Wisp in System Settings."], timing: &timing)
            return
        }
        let shots: [CapturedScreen]
        do {
            guard let captured = try await withTimeout(seconds: 10, { try await captureTask.value }) else {
                captureTask.cancel()
                throw ScreenCapturer.CaptureError.failed("timed out")
            }
            shots = captured
            guard isCurrent(turnID) else { return }
            // When the capture actually finished (it runs during the hold, not after key-up).
            guard let first = shots.first else { throw ScreenCapturer.CaptureError.noDisplay }
            timing.captureStart = first.record.capturedAtUptime
            timing.captureReady = first.record.capturedAtUptime + (first.captureMilliseconds + first.resizeMilliseconds) / 1000
        } catch {
            timing.outcome = "capture_failed"
            guard isCurrent(turnID) else { return }
            if case ScreenCapturer.CaptureError.permissionDenied = error {
                // Screen access lapsed (macOS asks again every so often): show the card that fixes it.
                app.permissions.refresh()
                onNeedsPermission?(.screenRecording)
                await say(["I can't see your screen right now. Turn Screen Recording back on for Wisp."], timing: &timing)
            } else {
                await say(["I couldn't take a screenshot just now. Try again in a moment."], timing: &timing)
            }
            return
        }
        let shot = shots[0]
        // A black screenshot (protected window, sleeping display) still answers questions that aren't about
        // the screen; the model is told it can't see, and nothing is pointed at.
        if shot.looksBlank { timing.outcome = "blank_capture" }
        let jpegs = shots.compactMap { $0.jpegData() }
        guard jpegs.count == shots.count else {
            timing.outcome = "encode_failed"
            await say(["I couldn't take a screenshot just now. Try again in a moment."], timing: &timing)
            return
        }
        let records = shots.map(\.record)
        let recordFor: @Sendable (AssistantEvent) -> (AssistantEvent, CaptureRecord) = { event in
            let (index, inner) = event.screenAndEvent
            return (inner, records[min(index, records.count - 1)])
        }
        // The text on the main screenshot, read while the model answers (on this Mac, kept only for this turn). It
        // confirms a point the model adds to a question it labelled "other" before that point is shown.
        let mainShot = shots[0]
        let screenText = Task.detached(priority: .userInitiated) { ScreenText.recognize(mainShot.image) }
        defer { screenText.cancel() }

        // No internet: say so right away (and what still works) instead of waiting for the request to time out.
        let aiHost = URL(string: app.config.vision.baseURL)?.host?.lowercased() ?? ""
        let localAI = aiHost == "localhost" || aiHost.hasPrefix("127.") || aiHost == "::1" || aiHost.hasSuffix(".local")
        if isOffline?() == true, !localAI {
            timing.outcome = "offline"
            await say(["I'm offline right now, so I can't answer that. I can still read text aloud, copy the text on your screen and set timers."], timing: &timing)
            return
        }

        // 3. Ask the model; speak sentences and point as events stream in.
        let vision = app.config.vision
        let provider = VisionProvider(configID: vision.providerID)
        var noPointing = !QuestionIntent.allowsPointing(question)
        var topicSaysOther = false
        // Read on the main actor now; the policy check itself runs on the network task.
        let disclosureAccepted = app.config.privacy.cloudDisclosureAccepted
        guard !vision.modelID.trimmingCharacters(in: .whitespaces).isEmpty else {
            timing.outcome = "no_model"
            await say(["Choose an AI model in Wisp Settings, under AI."], timing: &timing)
            return
        }
        guard let base = URL(string: vision.baseURL), base.scheme?.hasPrefix("http") == true else {
            timing.outcome = "bad_base_url"
            await say(["Something is wrong with Wisp's AI settings. Open Wisp Settings, choose AI, and pick your provider again."], timing: &timing)
            return
        }
        let client = VisionClient(baseURL: base,
                                  policy: ConsentPolicyGate(disclosureAccepted: { disclosureAccepted }),
                                  apiKey: { APIKeyStore.key(for: provider) }, requiresKey: provider.requiresKey, wire: provider.wire)
        let engine = AssistantEngine(client: client)
        var models = [vision.modelInfo]
        if provider == .nvidiaNIM {
            models += vision.fallbackModelIDs.filter { $0 != vision.modelID }.map { VisionModelCatalog.info(for: $0) }
            // Smart routing: quick how-to questions to the fast model, everything else to the stronger one.
            if vision.smartRouting {
                models = QuestionRouter.models(for: question, fallbacks: vision.fallbackModelIDs).map { VisionModelCatalog.info(for: $0) }
            }
        }
        // A second opinion starts with the next model in line (on NVIDIA: Nemotron 3.5 Super VL, more careful, a bit slower).
        if secondOpinion, models.count > 1 { models.swapAt(0, 1) }
        let space = models[0].coordinateSpace
        let modelList = models
        let snippets = await context.context(for: ContextRequest(transcript: question, frontmostBundleID: shot.record.frontmostBundleID))
        guard isCurrent(turnID) else { return }
        var facts = TurnFacts(imageSize: shot.record.sentPixels, cursorInImage: shot.record.cursorInImage,
                              frontmostAppName: frontmostName.removeValue(forKey: input.id), question: question,
                              context: snippets)
        facts.otherScreens = shots.dropFirst().map(\.record.sentPixels)
        // Where the pointer is now, at key-up: people often move onto the thing they mean while talking.
        let mouseNow = NSEvent.mouseLocation
        if shot.record.displayFrame.contains(Vec2(mouseNow.x, mouseNow.y)) {
            facts.cursorInImage = shot.record.imagePoint(fromGlobal: Vec2(mouseNow.x, mouseNow.y))
        }
        facts.userInstructions = vision.instructions
        if let front = shot.record.frontmostBundleID, app.config.privacy.privateApps.contains(front) {
            facts.privateFrontApp = true
        }
        facts.answerLength = vision.answerLength
        if QuestionIntent.mentionsClipboard(question), let clip = NSPasteboard.general.string(forType: .string) {
            facts.clipboardText = UIContext.cleanSelection(clip)
        }
        // A how-to question may become a walkthrough: the model says whether more steps follow its answer.
        facts.guideText = input.guideText ?? guideTextForQuestion?(question)
            ?? (app.config.guideSteps && GuideSession.isTask(question) ? GuideSession.firstStepText : nil)
        facts.screenLooksBlank = shot.looksBlank
        // The front app's controls and menus (started at key-down; normally finished long before key-up).
        var controlsBySpace: [ModelCoordinateSpace: [ControlLine]] = [:]
        var menuCommands: [String] = []
        if let read = uiReads.removeValue(forKey: input.id),
           var ui = (try? await withTimeout(seconds: 0.4, { await read.value })) ?? nil, !ui.isEmpty, !shot.looksBlank {
            let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
            let point = CGPoint(x: mouseNow.x, y: primaryHeight - mouseNow.y)
            let privateApps = Set(app.config.privacy.privateApps)
            if let now = await Task.detached(priority: .userInitiated, operation: {
                UIContextReader.elementUnderPointer(point, primaryHeight: primaryHeight, privateApps: privateApps)
            }).value {
                ui.underPointer = now
            }
            for space in Set(modelList.map(\.coordinateSpace)) {
                let controls = UIContextFormat.controlLines(ui, record: shot.record, space: space)
                controlsBySpace[space] = controls
                let pointer = ui.underPointer.flatMap { UIContextFormat.controlLine($0, record: shot.record, space: space) }
                facts.uiContextTexts[space] = UIContextFormat.text(appName: ui.appName, controls: controls, menus: ui.menus, space: space,
                                                                   selectedText: ui.selectedText, underPointer: pointer,
                                                                   fullScreen: ui.fullScreen == true, windowUnreadable: ui.windowUnreadable)
            }
            menuCommands = ui.menus.map(\.title)
            Log.vision.info("app details: \(ui.elements.count, privacy: .public) controls, \(ui.menus.count, privacy: .public) menu items")
        }
        guard isCurrent(turnID) else { return }
        if shot.looksBlank { noPointing = true }

        let (sentences, sentenceSink) = AsyncStream.makeStream(of: String.self)
        // Visual events wait for the sentence they follow, so the cursor moves as that sentence is spoken.
        let pendingVisuals = VisualQueue()
        // In a call (another app is recording): answer quietly so Wisp's voice doesn't go into the call.
        let quiet = input.silent || (app.config.speech.quietDuringCalls && app.config.speech.speakAnswers && AudioDevices.inputInUseElsewhere())
        if quiet {
            onQuietAnswer?(true)
            timing.outcome = "quiet"
        }
        let voice = (neuralVoice?.isReady == true ? neuralVoice : nil) ?? systemVoice
        timing.ttsEngine = voice === systemVoice ? "system" : "kokoro"
        speaking = voice
        let firstAudio = FirstFlag()
        let speakTask = Task { @MainActor [weak self] in
            await voice.speak(sentences, onSentenceStart: { index, text in
                Task { @MainActor in
                    // A cut-off answer (barge-in, Stop) must not caption its next sentence.
                    guard self?.isCurrent(turnID) == true else { return }
                    self?.onCaption?(text)
                    for item in pendingVisuals.startSentence(index) {
                        let (inner, record) = recordFor(item.event)
                        self?.onVisual?(inner, record, item.space)
                    }
                }
            }, onFirstAudio: { firstAudio.set() })
        }

        timing.requestSent = ProcessInfo.processInfo.systemUptime
        var answer: [String] = []
        // A slow service (or a fallback after a timeout) can take a while: say so instead of going quiet.
        let spoke = SpokeFlag()
        let thinking = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, !spoke.value, self.isCurrent(turnID) else { return }
            self.onStatusCaption?("Still thinking…")
        }
        defer { thinking.cancel() }
        var sentenceIndex = -1
        var lastSentence = ""
        var greyedTargets: [String] = []
        var stepsMore: Bool?
        /// What the first shown visual is called, in case the reply forgets to say anything.
        var firstShownLabel: String?
        var replies = engine.ask(jpegs: jpegs, facts: facts, models: modelList,
                                 frontmostBundleID: shot.record.frontmostBundleID,
                                 firstTokenTimeout: min(vision.timeoutSeconds, 20), totalTimeout: vision.timeoutSeconds + 20)
        // A walkthrough's next step is short: hear it all first, and if it only repeats the step they already did
        // (the screen hadn't caught up yet), don't say it; Wisp keeps watching instead.
        if facts.guideText != nil, let isRepeat = isGuideRepeat {
            var all: [AssistantOutput] = []
            for await output in replies { all.append(output) }
            guard isCurrent(turnID) else { sentenceSink.finish(); speakTask.cancel(); return } // a newer turn owns `speaking`
            let firstVisual = all.lazy.compactMap { output -> (AssistantEvent, ModelCoordinateSpace)? in
                if case .event(let event, let eventSpace) = output, event.isVisual { return (event, eventSpace) }
                return nil
            }.first
            let target: Vec2? = firstVisual.flatMap { event, eventSpace in
                let (inner, record) = recordFor(event)
                guard let anchor = VisualDecision.anchor(inner) else { return nil }
                return record.globalPoint(fromModel: anchor.0, anchor.1, space: eventSpace)
            }
            if let firstVisual, isRepeat(target, firstVisual.0.label ?? "") {
                Log.vision.info("guide: next step only repeated the last one; waiting instead")
                timing.outcome = "guide_repeat"
                sentenceSink.finish()
                await speakTask.value
                timing.done = ProcessInfo.processInfo.systemUptime
                speaking = nil
                onCaption?(nil)
                onGuideRepeat?()
                return
            }
            replies = AsyncStream { continuation in
                for output in all { continuation.yield(output) }
                continuation.finish()
            }
        }
        for await output in replies {
            switch output {
            case .event(.topic(let topic), _):
                // The model's own reading of the question. When it says the question isn't about the screen, only a
                // visual that the spoken sentence itself names is still shown (the model sometimes answers a
                // "what's First Aid?" from the screen after labelling it general knowledge).
                if topic != .screen { topicSaysOther = true }
            case .event(.steps(let more), _):
                stepsMore = more
            case .event(.say(let text), _):
                spoke.value = true
                if timing.firstSentence == nil { timing.firstSentence = ProcessInfo.processInfo.systemUptime }
                for raw in SentenceSplitter.split(text) {
                    // Off-screen answers are said straight, without a "can't help / don't see, but" hedge first.
                    let sentence = topicSaysOther ? QuestionIntent.withoutHedge(raw) : raw
                    sentenceIndex += 1
                    lastSentence = sentence
                    answer.append(sentence)
                    sentenceSink.yield(sentence)
                }
            case .event(let visual, let eventSpace):
                Log.vision.info("answer included a visual (sentence \(sentenceIndex, privacy: .public))")
                if noPointing { continue } // blank screen: nothing to show
                // The shared rules (VisualDecision): question type, denials and questions back, "other" answers kept
                // only when the thing is really there, points moved onto the app control they name.
                let turnInfo = VisualDecision.Turn(question: question, topicSaysOther: topicSaysOther,
                                                   controls: controlsBySpace[eventSpace] ?? [],
                                                   reach: VisualDecision.reach(space: eventSpace, sentPixels: shot.record.sentPixels),
                                                   menuCommands: menuCommands)
                let text = topicSaysOther ? await Self.screenText(from: screenText) : nil
                let record = recordFor(visual).1
                guard let shown = VisualDecision.decide(visual, after: lastSentence, turn: turnInfo, textConfirms: { event in
                    Self.confirmedOnScreen(event, record: record, space: eventSpace, text: text) != nil
                }) else { continue }
                if let greyed = VisualDecision.greyedOutTarget(shown, turn: turnInfo) { greyedTargets.append(greyed.label) }
                if firstShownLabel == nil { firstShownLabel = shown.label ?? "" }
                let shownSpace = eventSpace
                // Shown when the sentence it follows starts being spoken (right away if that already happened).
                if pendingVisuals.add(VisualQueue.Item(event: shown, space: shownSpace), sentence: sentenceIndex), isCurrent(turnID) {
                    let (inner, record) = recordFor(shown)
                    onVisual?(inner, record, shownSpace)
                }
            case .finished(let vt, let error):
                timing.model = vt.modelID
                timing.attempts = vt.attempts
                timing.firstToken = vt.firstTokenUptime
                if let error, answer.isEmpty {
                    timing.outcome = "vision_" + error.code
                    if isCurrent(turnID) { sentenceSink.yield(error.userMessage) }
                }
            }
        }
        // A walkthrough's last reply can be just "STEPS: done": say it's finished.
        if isCurrent(turnID), answer.isEmpty, firstShownLabel == nil, stepsMore == false, facts.guideText != nil {
            let line = "That's it, you're all set."
            answer.append(line)
            sentenceSink.yield(line)
        }
        // A reply that only points (small models sometimes skip the sentence) still says where.
        if isCurrent(turnID), answer.isEmpty, let label = firstShownLabel {
            let line = label.isEmpty ? "Here." : "Here: \(label)."
            answer.append(line)
            sentenceSink.yield(line)
        }
        // Pointing at a control macOS reports as greyed out: say so if the answer didn't.
        if isCurrent(turnID), let note = VisualDecision.greyedOutNote(labels: greyedTargets, answer: answer) {
            answer.append(note)
            sentenceSink.yield(note)
        }
        sentenceSink.finish()
        // Anything still queued (e.g. a visual after the last sentence) shows now, unless a new turn started.
        let leftovers = pendingVisuals.takeAll()
        if isCurrent(turnID) {
            for item in leftovers {
                let (inner, record) = recordFor(item.event)
                onVisual?(inner, record, item.space)
            }
        }
        await speakTask.value
        if quiet {
            onQuietAnswer?(false)
            if isCurrent(turnID), !answer.isEmpty { onQuietResult?(question, answer.joined(separator: " ")) }
            timing.outcome = "ok"
        }
        if let t = firstAudio.time { timing.firstAudio = t }
        if isCurrent(turnID), !timing.outcome.hasPrefix("vision_"), !answer.isEmpty {
            onStepsStatus?(stepsMore)
            onAnswered?(question, answer)
        }
        timing.done = ProcessInfo.processInfo.systemUptime
        guard isCurrent(turnID) else { return }
        speaking = nil
        onCaption?(nil)
    }

    private func isCurrent(_ id: UUID) -> Bool { currentTurn == id }

    /// The screenshot's text if recognition has finished (or finishes within a moment); nil otherwise, so a slow
    /// first run of Vision can only skip the snap, never hold up the answer.
    private static func screenText(from task: Task<ScreenText?, Never>) async -> ScreenText? {
        guard let result = try? await withTimeout(seconds: 1.0, { await task.value }) else { return nil }
        return result ?? nil // withTimeout wraps the value in one more optional (nil = timed out)
    }

    /// A visual on the main screenshot whose label is written on screen within reach of it, unchanged. (Moving the
    /// point onto the text was measured: it broke icon buttons whose name sits beside them and fixed nothing.)
    nonisolated public static func confirmedOnScreen(_ event: AssistantEvent, record: CaptureRecord, space: ModelCoordinateSpace,
                                  text: ScreenText?) -> (AssistantEvent, ModelCoordinateSpace)? {
        let (screen, inner) = event.screenAndEvent
        guard screen == 0, let text, let label = inner.label, !label.isEmpty else { return nil }
        let anchor: Vec2
        switch inner {
        case .point(let x, let y, _): anchor = Vec2(x, y)
        case .circle(let x, let y, let w, let h, _): anchor = Vec2(x + w / 2, y + h / 2)
        case .underline(let x1, let y1, let x2, let y2, _): anchor = Vec2((x1 + x2) / 2, (y1 + y2) / 2)
        case .arrow(_, _, let x2, let y2, _): anchor = Vec2(x2, y2)
        case .path(let points, _): guard let first = points.first else { return nil }; anchor = first
        default: return nil
        }
        guard let global = record.globalPoint(fromModel: anchor.x, anchor.y, space: space) else { return nil }
        let p = record.imagePoint(fromGlobal: global)
        let reach = Double(max(record.sentPixels.width, record.sentPixels.height)) * 0.12
        guard text.box(for: label, near: p, maxDistance: reach) != nil else { return nil }
        return (event, space)
    }


    /// Plays the "problem" sound and shows `text` as a caption for a moment, without speaking.
    public var onNoticeSound: (() -> Void)?
    /// Why speech-to-text isn't usable yet (downloading, offline, failed), for the spoken reply.
    public var speechProblem: (() -> String?)?
    /// A permission turned out to be off when it was needed: show its recovery card.
    public var onNeedsPermission: ((PermissionKind) -> Void)?

    /// Status captions that aren't speech ("Still thinking…", microphone problems): shown without changing the
    /// companion's state (the thinking dots stay while Wisp is still thinking).
    public var onStatusCaption: ((String?) -> Void)?

    /// Shows a caption for a moment without speaking (problems found outside the pipeline, e.g. the microphone).
    public func showCaption(_ text: String, seconds: Double = 3) {
        onStatusCaption?(text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.onStatusCaption?(nil)
        }
    }

    private func notice(_ text: String) async {
        onNoticeSound?()
        onStatusCaption?(text)
        try? await Task.sleep(for: .seconds(2.5))
        onStatusCaption?(nil)
    }

    /// Reads text word for word in Wisp's voice, with captions (selected text; nothing leaves the Mac).
    /// Another app is recording (a call) and the user wants quiet answers then.
    private var inCall: Bool {
        app.config.speech.quietDuringCalls && app.config.speech.speakAnswers && AudioDevices.inputInUseElsewhere()
    }

    private func readAloud(_ text: String, timing: inout TurnTiming) async {
        let quiet = inCall
        if quiet { onQuietAnswer?(true) }
        defer { if quiet { onQuietAnswer?(false) } }
        let sentences = SentenceSplitter.split(text).flatMap { Self.chunked($0) }
        let (stream, sink) = AsyncStream.makeStream(of: String.self)
        sentences.forEach { sink.yield($0) }
        sink.finish()
        let voice = (neuralVoice?.isReady == true ? neuralVoice : nil) ?? systemVoice
        timing.ttsEngine = voice === systemVoice ? "system" : "kokoro"
        speaking = voice
        let first = FirstFlag()
        await voice.speak(stream, onSentenceStart: { [weak self] _, text in
            Task { @MainActor in if self?.speaking === voice { self?.onCaption?(text) } }
        }, onFirstAudio: { first.set() })
        timing.firstAudio = first.time
        if speaking === voice {
            speaking = nil
            onCaption?(nil)
        }
    }

    /// Splits a very long sentence (a list, a heading run into text) at commas or spaces so captions and the
    /// voice get pieces of a readable size.
    static func chunked(_ sentence: String, limit: Int = 220) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            if current.count + word.count + 1 > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
            if current.count > limit / 2, word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private func isPrivate(_ pid: pid_t) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return app.config.privacy.privateApps.contains(id)
    }

    /// The text writing help works on: the selection, or else the front window's text (read on this Mac).
    private func writingSource(pid: pid_t) async -> String? {
        if let selection = await Task.detached(priority: .userInitiated, operation: { UIContextReader.fullSelection(pid: pid) }).value {
            return selection
        }
        guard app.permissions.snapshot[.screenRecording].isUsable else { return nil }
        onStatusCaption?("Reading the page…")
        defer { onStatusCaption?(nil) }
        return await Self.windowText(pid: pid, privateApps: Set(app.config.privacy.privateApps)).map { String($0.prefix(12_000)) }
    }

    /// Streams a sketch of `subject` and hands over each stroke as soon as its line is complete. On NVIDIA it uses
    /// Step 5 Preview (the best sketcher; it sometimes thinks too long and draws nothing) and then Nemotron 3.5 Super VL.
    /// Returns how many strokes were drawn.
    private func sketch(_ subject: String, stroke: @escaping ([Vec2]) -> Void) async -> Int {
        let vision = app.config.vision
        let provider = VisionProvider(configID: vision.providerID)
        guard let base = URL(string: vision.baseURL) else { return 0 }
        let disclosureAccepted = app.config.privacy.cloudDisclosureAccepted
        let client = VisionClient(baseURL: base, policy: ConsentPolicyGate(disclosureAccepted: { disclosureAccepted }),
                                  apiKey: { APIKeyStore.key(for: provider) }, requiresKey: provider.requiresKey, wire: provider.wire)
        let models: [VisionModelInfo] = provider == .nvidiaNIM
            ? [QuestionRouter.drawingModelID, QuestionRouter.strongModelID].map { VisionModelCatalog.info(for: $0) }
            : [vision.modelInfo]
        for model in models {
            var drawn = 0
            var buffer = ""
            let request = VisionRequest(model: model, systemPrompt: Drawing.sketchPrompt, userText: "Draw: \(subject)",
                                        jpegs: [], maxTokens: 3000, temperature: 0.3)
            do {
                for try await chunk in client.stream(request, frontmostBundleID: nil, firstTokenTimeout: 45, totalTimeout: 90) {
                    buffer += chunk
                    while let newline = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newline])
                        buffer = String(buffer[buffer.index(after: newline)...])
                        if let points = Drawing.parseStroke(line) { stroke(points); drawn += 1 }
                    }
                }
                if let points = Drawing.parseStroke(buffer) { stroke(points); drawn += 1 }
                if drawn > 0 { return drawn }
            } catch {
                if drawn > 0 { return drawn } // keep what's drawn; never start a second drawing on top
            }
        }
        return 0
    }

    /// Review only: sketches `subject` exactly as "draw …" does (same models and prompt, strokes drawn as they arrive),
    /// without speaking. Returns how many strokes were drawn.
    public func reviewSketch(_ subject: String) async -> Int {
        guard let begin = onSketchBegin, let stroke = onSketchStroke else { return 0 }
        begin()
        return await sketch(subject) { points in stroke(points) }
    }

    /// Asks the fast model which single menu command does `task` (text only). Returns "Menu > Command" or nil.
    public func chooseMenuCommand(task: String, commands: [String], appName: String) async -> String? {
        let vision = app.config.vision
        let provider = VisionProvider(configID: vision.providerID)
        guard let base = URL(string: vision.baseURL) else { return nil }
        let disclosureAccepted = app.config.privacy.cloudDisclosureAccepted
        let client = VisionClient(baseURL: base, policy: ConsentPolicyGate(disclosureAccepted: { disclosureAccepted }),
                                  apiKey: { APIKeyStore.key(for: provider) }, requiresKey: provider.requiresKey, wire: provider.wire)
        let models = provider == .nvidiaNIM ? [QuestionRouter.fastModelID, QuestionRouter.strongModelID].map { VisionModelCatalog.info(for: $0) }
                                            : [vision.modelInfo]
        let system = "You pick menu commands. Given what someone wants to do in an app and the app's menu commands, reply with the one command that does it in a single step, exactly as listed (\"Menu > Command\"), or NONE if no single command does it. Reply with nothing else."
        let user = "App: \(appName)\nThey want to: \(task)\nMenu commands:\n" + commands.prefix(250).joined(separator: "\n")
        for model in models {
            var text = ""
            do {
                for try await chunk in client.stream(VisionRequest(model: model, systemPrompt: system, userText: user, jpegs: [], maxTokens: 60, temperature: 0),
                                                     frontmostBundleID: nil, firstTokenTimeout: 12, totalTimeout: 20) { text += chunk }
            } catch { continue }
            let answer = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"`.")))
            if answer.uppercased().hasPrefix("NONE") || answer.isEmpty { return nil }
            return answer.components(separatedBy: "\n").first
        }
        return nil
    }

    /// Asks the AI for the rewritten text (no screenshot), with the same provider and fallbacks as questions.
    private func write(request: String, selection: String) async -> Result<String, VisionError> {
        let vision = app.config.vision
        let provider = VisionProvider(configID: vision.providerID)
        guard let base = URL(string: vision.baseURL) else { return .failure(.network("bad address")) }
        let disclosureAccepted = app.config.privacy.cloudDisclosureAccepted
        let client = VisionClient(baseURL: base, policy: ConsentPolicyGate(disclosureAccepted: { disclosureAccepted }),
                                  apiKey: { APIKeyStore.key(for: provider) }, requiresKey: provider.requiresKey, wire: provider.wire)
        var models = [vision.modelInfo]
        if provider == .nvidiaNIM { models += vision.fallbackModelIDs.filter { $0 != vision.modelID }.map { VisionModelCatalog.info(for: $0) } }
        if provider == .nvidiaNIM, vision.smartRouting {
            models = QuestionRouter.models(for: request, fallbacks: vision.fallbackModelIDs).map { VisionModelCatalog.info(for: $0) }
        }
        var lastError = VisionError.timeout
        onStatusCaption?("Writing…")
        defer { onStatusCaption?(nil) }
        for model in models {
            let req = VisionRequest(model: model, systemPrompt: WritingHelp.systemPrompt,
                                    userText: WritingHelp.userText(request: request, selection: selection),
                                    jpegs: [], maxTokens: 1500, temperature: 0.3)
            var text = ""
            do {
                for try await chunk in client.stream(req, frontmostBundleID: nil, firstTokenTimeout: 20, totalTimeout: 60) { text += chunk }
                let withoutThinking = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
                let cleaned = WritingHelp.cleaned(withoutThinking)
                if !cleaned.isEmpty { return .success(cleaned) }
            } catch let error as VisionError {
                lastError = error
                if !error.isRetryableWithAnotherModel { break }
            } catch {
                lastError = .network("failed")
            }
        }
        return .failure(lastError)
    }

    /// The text of `pid`'s front window, read from a full-resolution screenshot of it (on this Mac; nothing is sent).
    public func windowText(pid: pid_t) async -> String? {
        guard app.permissions.snapshot[.screenRecording].isUsable else { onNeedsPermission?(.screenRecording); return nil }
        return await Self.windowText(pid: pid, privateApps: Set(app.config.privacy.privateApps))
    }

    nonisolated public static func windowText(pid: pid_t, privateApps: Set<String>) async -> String? {
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, privateApps.contains(id) { return nil }
        // The app's frontmost normal window (the list is in front-to-back order).
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                                              && (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) > 200 }),
              let number = info[kCGWindowNumber as String] as? Int else { return nil }
        guard let image = try? await ScreenCapturer().captureWindow(id: CGWindowID(number)) else { return nil }
        // Skip the title bar (28 points at the window's scale).
        let scale = Double(image.width) / max(1, ((info[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? Double(image.width)))
        return await Task.detached(priority: .userInitiated) { ScreenText.readableText(image, skipTop: 28 * scale) }.value
    }

    /// Reads all the text on the display under the pointer (full resolution, on this Mac; private apps left out)
    /// and puts it on the clipboard. Returns the number of lines, or nil if the screen couldn't be read.
    public func copyScreenText() async -> Int? {
        guard app.permissions.snapshot[.screenRecording].isUsable else { onNeedsPermission?(.screenRecording); return nil }
        let full = ScreenCapturer()
        full.longEdge = 5120 // native resolution: small text stays readable
        full.letSystemScale = false
        full.showsCursor = false
        full.hiddenBundleIDs = Set(app.config.privacy.privateApps)
        guard let shot = try? await full.captureDisplay() else { return nil }
        let menuBar = Double(NSStatusBar.system.thickness) * shot.record.pointPixelScale + 2
        let text = await Task.detached(priority: .userInitiated) { ScreenText.readableText(shot.image, skipTop: menuBar) }.value
        guard let text else { return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text.split(separator: "\n").count
    }

    /// Reads the front app's selected text aloud (menu > Read Selection Aloud). False when nothing is selected
    /// or the permission is off.
    public func readSelectionAloud() async -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier, !isPrivate(pid),
              let text = await Task.detached(priority: .userInitiated, operation: { UIContextReader.fullSelection(pid: pid) }).value
        else { return false }
        stopSpeaking()
        currentTurn = nil
        var timing = TurnTiming(keyDown: ProcessInfo.processInfo.systemUptime)
        await readAloud(text, timing: &timing)
        return true
    }

    /// Says an earlier answer again (menu > Say Last Answer Again), with captions, no pointing.
    public func speakAgain(_ sentences: [String]) {
        stopSpeaking()
        currentTurn = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let quiet = self.inCall
            if quiet { self.onQuietAnswer?(true) }
            defer { if quiet { self.onQuietAnswer?(false) } }
            let (stream, sink) = AsyncStream.makeStream(of: String.self)
            sentences.forEach { sink.yield($0) }
            sink.finish()
            let voice = (self.neuralVoice?.isReady == true ? self.neuralVoice : nil) ?? self.systemVoice
            self.speaking = voice
            await voice.speak(stream, onSentenceStart: { [weak self] _, text in
                Task { @MainActor in if self?.speaking === voice { self?.onCaption?(text) } }
            }, onFirstAudio: {})
            if self.speaking === voice {
                self.speaking = nil
                self.onCaption?(nil)
            }
        }
    }

    /// Speaks a short status message in Wisp's own voice (the system voice only while it is still downloading).
    private func say(_ sentences: [String], timing: inout TurnTiming) async {
        let quiet = inCall
        if quiet { onQuietAnswer?(true) }
        defer { if quiet { onQuietAnswer?(false) } }
        let (stream, sink) = AsyncStream.makeStream(of: String.self)
        sentences.forEach { sink.yield($0) }
        sink.finish()
        let voice = (neuralVoice?.isReady == true ? neuralVoice : nil) ?? systemVoice
        timing.ttsEngine = voice === systemVoice ? "system" : "kokoro"
        speaking = voice
        onProblem?(sentences.joined(separator: " "))
        let first = FirstFlag()
        await voice.speak(stream, onSentenceStart: { [weak self] _, text in
            Task { @MainActor in self?.onCaption?(text) }
        }, onFirstAudio: { first.set() })
        timing.firstAudio = first.time
        speaking = nil
        onCaption?(nil)
    }

    private func keyterms() -> [String] {
        var terms = ["Wisp"]
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { terms.append(app) }
        return terms
    }
}

/// Holds visual events until the sentence they follow starts being spoken.
final class VisualQueue: @unchecked Sendable {
    struct Item { var event: AssistantEvent; var space: ModelCoordinateSpace }
    private let lock = NSLock()
    private var items: [(Int, Item)] = []
    private var started = -1

    /// Queues `item` for `sentence` (-1 = before any sentence). Returns true when it should be shown right now
    /// because that sentence is already being spoken (or there is no sentence to wait for).
    func add(_ item: Item, sentence: Int) -> Bool {
        lock.withLock {
            if sentence < 0 || sentence <= started { return true }
            items.append((sentence, item))
            return false
        }
    }

    /// A sentence started: returns the items waiting for it (and any earlier ones).
    func startSentence(_ sentence: Int) -> [Item] {
        lock.withLock {
            started = max(started, sentence)
            let ready = items.filter { $0.0 <= sentence }.map(\.1)
            items.removeAll { $0.0 <= sentence }
            return ready
        }
    }

    func takeAll() -> [Item] {
        lock.withLock {
            let all = items.map(\.1)
            items.removeAll()
            return all
        }
    }
}

/// Records the first time something happened, thread-safely.
final class FirstFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func set() { lock.withLock { if value == nil { value = ProcessInfo.processInfo.systemUptime } } }
    var time: Double? { lock.withLock { value } }
}

/// Set once the answer has started (main actor only).
@MainActor
final class SpokeFlag { var value = false }

/// Runs `operation`, returning nil if it hasn't finished within `seconds` (the operation is cancelled).
@MainActor
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); return nil }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}
