import AppKit
import AVFoundation
import Combine
import os
import SwiftUI
import WispCore

/// Owns every long-lived service and window. The app target's delegate creates one of these.
@MainActor
public final class WispAppController {
    public let app: AppState
    public let statusItem: StatusItemController
    public let recovery: RecoveryCardController
    public let overlay: OverlayController
    public let turns: TurnCoordinator
    public let pipeline: TurnPipeline
    public let models: ModelManager?
    public let captions = CaptionController()
    public let kokoro = KokoroSpeechEngine()
    public let askBox = AskBoxController()
    public let answerCard = AnswerCardController()
    public let shortcutsCard = ShortcutsCardController()
    public let magnifier = MagnifierController()
    private lazy var webActor = WebActor(overlay: overlay)
    private lazy var appActor: AppActor = {
        let actor = AppActor(overlay: overlay)
        actor.chooseWithAI = { [weak self] task, commands, name in await self?.pipeline.chooseMenuCommand(task: task, commands: commands, appName: name) }
        return actor
    }()
    /// The current turn was typed (its answer also goes in the answer card).
    private var typedTurnActive = false
    private var configObservation: AnyCancellable?
    /// The last few answers (memory only; gone when Wisp quits).
    private var recent = RecentAnswers()
    /// Every question and answer (saved on the Mac only if the user keeps history).
    private var history = History()
    private var historyWindow: NSWindow?
    private weak var historyModel: HistoryModel?
    private static var historyURL: URL { AppPaths.applicationSupport.appendingPathComponent("history.json") }
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var whatsNewWindow: NSWindow?
    private var checkupWindow: NSWindow?
    private var windowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Settings tabs contributed by features.
    /// Voice changes are applied in order on one queue; `desiredVoice` is always the latest choice.
    private let voiceQueue = DispatchQueue(label: "com.zakvirani.wisp.voice", qos: .userInitiated)
    private let desiredVoice = OSAllocatedUnfairLock(initialState: VoiceCatalog.defaultID)
    public var settingsTabs: [SettingsTab] = []
    private let settingsNavigation = SettingsNavigation()
    /// Set by the app before `start()` (Sparkle lives in the app target).
    public var updater: AppUpdater? {
        didSet {
            statusItem.onCheckForUpdates = updater?.isConfigured == true ? { [weak self] in self?.updater?.checkForUpdates() } : nil
        }
    }

    public init() {
        let store = ConfigStore.standard(appSupportDirectory: AppPaths.applicationSupport)
        for warning in store.loadWarnings {
            Log.app.error("config: \(warning, privacy: .public)")
        }
        let permissions = PermissionService()
        app = AppState(configStore: store, permissions: permissions)
        statusItem = StatusItemController(app: app)
        recovery = RecoveryCardController(app: app)
        overlay = OverlayController()
        turns = TurnCoordinator(app: app, overlay: overlay, recovery: recovery)
        pipeline = TurnPipeline(app: app)
        models = Self.makeModelManager(app: app)
        overlay.menuBarAnchor = { [weak statusItem] in statusItem?.anchorPoint }
        overlay.onLeftHome = { [weak statusItem] in statusItem?.companionAway = true }
        overlay.onArrivedHome = { [weak statusItem] in
            statusItem?.companionAway = false
            statusItem?.playArrivalBounce()
        }
        overlay.apply(app.config.overlay)
        turns.onTurnBegan = { [pipeline] id, uptime in pipeline.turnBegan(id, at: uptime) }
        turns.onTurnCancelled = { [pipeline] id in pipeline.turnCancelled(id) }
        turns.onAudioChunk = { [pipeline] samples in pipeline.audioChunk(samples) }
        pipeline.onTiming = { [weak app] timing in
            TimingLog.shared.record(timing)
            if timing.outcome == "ok" { Task { @MainActor in app?.answeredQuestions += 1 } }
        }
        app.replayWelcome = { [weak self] in self?.replayWelcome() }
        TimingLog.shared.setEnabled(app.config.privacy.localTimingLog)
        pipeline.neuralVoice = kokoro
        var gestureSeed = 0
        pipeline.onVisual = { [weak self, overlay] event, record, space in
            self?.noteTarget(event, record: record, space: space)
            gestureSeed += 1
            if let gesture = GesturePlanner.gesture(for: event, record: record, space: space, seed: gestureSeed) {
                overlay.perform(gesture)
            } else {
                Log.overlay.notice("dropped a visual with unusable coordinates")
            }
        }
        captions.avoidRect = { [overlay] in overlay.highlightRect }
        turns.onListeningStarted = { [weak self, pipeline, overlay, kokoro] id, keyDownAt in
            // A walkthrough waits while they talk: "what now?" carries on with it, anything else ends it.
            self?.suspendGuide()
            self?.typedTurnActive = false
            self?.answerCard.hide()
            overlay.clearDrawings()
            pipeline.listeningStarted(id, keyDownAt: keyDownAt)
            kokoro.stop() // a voice Preview must not play over the question
        }
        app.voiceAvailable = { [kokoro] id in
            kokoro.isReady && (id == VoiceCatalog.defaultID || kokoro.extraVoicesDirectory != nil)
        }
        app.previewVoice = { [kokoro, voiceQueue] id in
            guard kokoro.isReady else { NSSound.beep(); return }
            kokoro.stop()
            let name = VoiceCatalog.option(id).name
            voiceQueue.async {
                kokoro.selectVoice(id) // off the main thread (a voice pack is a 2.6 MB JSON file)
                let (stream, sink) = AsyncStream.makeStream(of: String.self)
                sink.yield("Hi, I'm \(name). Click the blue Export button in the bottom right corner, and you're all set.")
                sink.finish()
                Task { await kokoro.speak(stream, onSentenceStart: { _, _ in }, onFirstAudio: {}) }
            }
        }
        pipeline.onNoticeSound = { [turns] in turns.earcons.play(.problem) }
        pipeline.onNeedsPermission = { [recovery] kind in recovery.show(for: [kind]) }
        pipeline.speechProblem = { [weak self] in self?.models?.speechProblem }
        statusItem.isSpeaking = { [weak self] in !(self?.isIdle ?? true) }
        statusItem.onStopSpeaking = { [weak self] in self?.stopTurn() }
        // Escape stops Wisp while it's listening, thinking or speaking (it's ignored the rest of the time).
        turns.hotkey.onEscape = { [weak self] in
            if self?.magnifier.isVisible == true { self?.magnifier.hide() }
            guard let self, !self.isIdle || self.overlay.hasDrawings || self.guide != nil || self.answerCard.isVisible else { return }
            self.stopTurn()
            self.overlay.setMode(.hidden)
        }
        turns.onInterrupt = { [pipeline, overlay] in
            pipeline.stopSpeaking()
            overlay.clearDrawings()
        }
        statusItem.setupProblem = { [weak self] in
            guard let self else { return nil }
            if !APIKeyStore.isConnected(self.app.config.vision) { return "Connect Wisp's AI…" }
            if self.models?.isOffline == true, self.models?.speechProblem == nil { return "Offline: answers need the internet" }
            if let models = self.models, models.speechProblem != nil {
                return models.isOffline ? "Waiting for internet to finish setup" : "Downloading speech model…"
            }
            return nil
        }
        turns.onNotice = { [pipeline] text in pipeline.showCaption(text) }
        pipeline.onStatusCaption = { [captions] text in
            if let text { captions.show(text, always: true) } else { captions.hide() }
        }
        pipeline.onCaption = { [captions, overlay] text in
            if let text {
                captions.show(text)
                // Speaking now: drop the "thinking" dots.
                if overlay.mode == .thinking { overlay.setMode(.resting) }
            } else {
                captions.hide()
            }
        }
        captions.enabled = app.config.speech.effectiveShowCaptions
        captions.scale = app.config.speech.captionScale
        captions.atBottom = app.config.speech.captionPosition == "bottom"
        kokoro.speed = Float(app.config.speech.rate)
        kokoro.volume = Float(app.config.speech.effectiveVolume)
        kokoro.fallback = pipeline.systemVoice
        applySystemVoice()
        turns.process = { [pipeline] input in await pipeline.process(input) }

        settingsTabs = []
        if let models {
            settingsTabs.append(SettingsTab(id: "models", title: "Speech", symbol: "waveform") { [app] in
                ModelsSettingsView(models: models, app: app)
            })
        }
        settingsTabs.append(SettingsTab(id: "ai", title: "AI", symbol: "sparkles") { [app] in AISettingsView(app: app) })
        settingsTabs += [
            SettingsTab(id: "companion", title: "Companion", symbol: "cursorarrow.rays") { [app] in
                CompanionSettingsView(app: app)
            },
        ]
        turns.onTypedTurnStarted = { [pipeline] id in pipeline.typedTurnStarted(id) }
        turns.hotkey.onDoubleTap = { [weak self] in
            guard let self, self.app.config.typeToAsk else { return }
            self.askByTyping()
        }
        statusItem.onTypeQuestion = { [weak self] in self?.askByTyping() }
        askBox.actions = { [weak self] in self?.quickActions() ?? [] }
        pipeline.onShowShortcuts = { [weak self] name, pid, items in
            self?.shortcutsCard.show(appName: name, icon: NSRunningApplication(processIdentifier: pid)?.icon, items: items)
        }
        statusItem.onShortcuts = { [weak self] in self?.showShortcutsForFrontApp() }
        statusItem.onCopyScreenText = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch await self.pipeline.copyScreenText() {
                case nil: break
                case 0?: self.pipeline.showCaption("No text found on your screen.", seconds: 2.5)
                case let n?: self.pipeline.showCaption("Copied \(n) line\(n == 1 ? "" : "s") of text from your screen.", seconds: 2.5)
                }
            }
        }
        statusItem.onReadSelection = { [weak self] in
            guard let self else { return }
            guard UIContextReader.isAllowed else {
                self.pipeline.showCaption("To read selected text, turn on Better answers in Wisp Settings > Permissions.", seconds: 3.5)
                return
            }
            Task { @MainActor in
                if !(await self.pipeline.readSelectionAloud()) {
                    self.pipeline.showCaption("Select some text first, then choose Read Selection Aloud.", seconds: 3)
                }
            }
        }
        statusItem.onPause = { [weak self] length in self?.pause(until: PauseState.end(of: length, from: Date())) }
        statusItem.onResume = { [weak self] in self?.pause(until: nil) }
        turns.onPausedPress = { [weak self] in self?.pipeline.showCaption("Wisp is paused. Resume it from the Wisp menu.", seconds: 2.5) }
        pipeline.onAnswered = { [weak self] question, sentences in
            guard let self else { return }
            if !self.guideStepRunning {
                self.recent.add(question: question, sentences: sentences)
                self.recordHistory(question: question, answer: sentences.joined(separator: " "))
            }
            if !self.guideStepRunning, (self.typedTurnActive && self.app.config.answerCard) || self.app.config.answerCardAlways {
                self.answerCard.show(question: question, answer: sentences.joined(separator: " "), near: self.askBox.lastFrame)
            }
            self.typedTurnActive = false
            self.answerFinished(question: question, answer: sentences)
        }
        // Apps built on Electron only report their buttons when asked, and take a moment to build that list: ask
        // as soon as an app comes to the front (and now, for the one in front).
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            DispatchQueue.global(qos: .utility).async { UIContextReader.exposeControls(pid: pid) }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            DispatchQueue.global(qos: .utility).async { UIContextReader.exposeControls(pid: front) }
        }
        pipeline.onStepsStatus = { [weak self] more in self?.lastStepsMore = more }
        pipeline.isGuideRepeat = { [weak self] point, label in
            guard let self, let g = self.guide, self.guideRepeatsSkipped == 0 else { return false }
            return g.isRepeat(of: point, label: label)
        }
        pipeline.onGuideRepeat = { [weak self] in self?.guideRepeatSkipped() }
        pipeline.guideTextForQuestion = { [weak self] question in
            guard let self, let g = self.guide, !self.guideStepRunning, GuideSession.isContinuation(question) else { return nil }
            self.guideStepRunning = true   // answered as the next step
            self.watchStepTurn(generation: self.guideGeneration)
            return g.requestText
        }
        pipeline.onDraw = { [weak self] shape in self?.drawShape(shape) }
        pipeline.onWebAction = { [weak self] action in await self?.webActor.run(action) ?? action.spokenResult }
        pipeline.onAppAction = { [weak self] action in await self?.appActor.run(action) ?? "" }
        pipeline.onSketchBegin = { [weak self] in self?.beginSketch() }
        pipeline.onSketchStroke = { [weak self] points in self?.drawSketchStroke(points) }
        pipeline.onMagnify = { [weak self] in
            guard let self else { return false }
            return await self.magnifier.show(around: NSEvent.mouseLocation, privateApps: Set(self.app.config.privacy.privateApps))
        }
        pipeline.isOffline = { [weak self] in self?.models?.isOffline ?? false }
        pipeline.onTimerCommand = { [weak self] command in self?.handleTimer(command) ?? "" }
        notes = Notes.load(from: Self.notesURL)
        app.notesCount = notes.items.count
        pipeline.onNotesCommand = { [weak self] command in self?.handleNotes(command) ?? "" }
        app.clearNotes = { [weak self] in _ = self?.handleNotes(.clear) }
        statusItem.sections.append(StatusMenuSection { [weak self] in self?.timerMenuItems() ?? [] })
        pipeline.onQuietAnswer = { [weak self] quiet in
            guard let self else { return }
            if quiet {
                self.kokoro.volume = 0
                self.pipeline.systemVoice.volume = 0
                self.captions.enabled = true
                if !self.typedTurnActive { self.pipeline.showCaption("You're on a call, so I'll answer quietly.", seconds: 1.5) }
            } else {
                self.kokoro.volume = Float(self.app.config.speech.effectiveVolume)
                self.captions.enabled = self.app.config.speech.effectiveShowCaptions
                self.applySystemVoice()
            }
        }
        pipeline.onQuietResult = { [weak self] question, answer in
            guard let self, !self.typedTurnActive else { return } // typed answers get their card anyway
            self.answerCard.show(question: question, answer: answer, near: nil)
        }
        answerCard.onSayAgain = { [weak self] text in self?.pipeline.speakAgain(SentenceSplitter.split(text)) }
        pipeline.onWritingResult = { [weak self] request, text in
            guard let self else { return }
            self.answerCard.show(question: request, answer: text, near: self.askBox.lastFrame)
        }
        pipeline.onVoiceSettingsChanged = { [weak self] in
            guard let self else { return }
            self.kokoro.speed = Float(self.app.config.speech.rate)
            self.kokoro.volume = Float(self.app.config.speech.effectiveVolume)
            self.captions.enabled = self.app.config.speech.effectiveShowCaptions
            self.applySystemVoice()
        }
        pipeline.onRecall = { [weak self] topic in self?.history.recall(topic).map(\.answer) }
        pipeline.lastQuestion = { [weak self] in self?.recent.last?.question }
        pipeline.lastAnswer = { [weak self] in self?.recent.last?.sentences }
        statusItem.sections.append(StatusMenuSection { [weak self] in self?.recentAnswerItems() ?? [] })
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onOpenSettingsTab = { [weak self] tab in self?.showSettings(tab: tab) }
        statusItem.setupProblemTab = { [weak self] in
            guard let self else { return "general" }
            return APIKeyStore.isConnected(self.app.config.vision) ? "models" : "ai"
        }
        statusItem.onOpenOnboarding = { [weak self] in self?.replayWelcome() }
        statusItem.onWhatsNew = { [weak self] in self?.showWhatsNew(WhatsNew.entries) }
        statusItem.onCheckup = { [weak self] in self?.showCheckup() }
        statusItem.onHistory = { [weak self] in self?.showHistory() }
        if app.config.privacy.keepHistory { history = History.load(from: Self.historyURL) }
        app.openCheckup = { [weak self] in self?.showCheckup() }
        app.openWhatsNew = { [weak self] in self?.showWhatsNew(WhatsNew.entries) }
        statusItem.onFixPermissions = { [weak self] in self?.recovery.show() }
    }

    /// Call from `applicationDidFinishLaunching`.
    public func start(arguments: [String] = CommandLine.arguments) {
        let resume = arguments.contains(Relauncher.resumeArgument) && !app.config.onboardingCompleted
        let snapshot = app.permissions.refresh()
        Log.app.info("launch: onboarding=\(self.app.config.onboardingCompleted, privacy: .public) resume=\(resume, privacy: .public)")

        var forceOnboarding = false
        #if DEBUG
        forceOnboarding = arguments.contains("--show-onboarding") // review the welcome guide without resetting settings
        // --light / --dark: review Wisp's windows in the other appearance without changing the Mac's setting.
        if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        // --onboarding-step=N opens the guide at page N (review a page without stepping through the others).
        var debugStep = false
        if let arg = arguments.first(where: { $0.hasPrefix("--onboarding-step=") }), let n = Int(arg.dropFirst(18)) {
            UserDefaults.standard.set(n, forKey: "wisp.onboarding.step")
            forceOnboarding = true
            debugStep = true
        }
        // --settings=<tab> opens Settings on that tab (general, models, ai, companion, permissions, privacy, about).
        if let arg = arguments.first(where: { $0.hasPrefix("--settings=") }) { showSettings(tab: String(arg.dropFirst(11))) }
        // --caption shows a sample caption (review its look at the current caption size).
        if arguments.contains("--caption") || arguments.contains("--caption-bottom") {
            if arguments.contains("--caption-bottom") { captions.atBottom = true }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.captions.show("Click the blue Export button in the bottom right corner, and you're all set.", always: true)
            }
        }
        // --checkup opens the check-up window.
        if arguments.contains("--checkup") {
            Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(4)); self?.showCheckup() }
        }
        // --answer-card shows the answer card with sample text.
        if arguments.contains("--answer-card") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.answerCard.show(question: "how do I make a copy of this file", answer: "Choose File, then Duplicate, or press Shift Command S. The copy opens in a new window, ready to rename and save.", near: nil)
            }
        }
        // --shortcuts=<bundle id> shows that running app's shortcuts card.
        if let arg = arguments.first(where: { $0.hasPrefix("--shortcuts=") }),
           let target = NSRunningApplication.runningApplications(withBundleIdentifier: String(arg.dropFirst(12))).first {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                var items = UIContextReader.menuShortcuts(pid: target.processIdentifier)
                // WISP_SHORTCUTS_JSON: items read elsewhere (this debug build may not have the Accessibility permission).
                if items.isEmpty, let path = ProcessInfo.processInfo.environment["WISP_SHORTCUTS_JSON"],
                   let data = FileManager.default.contents(atPath: path),
                   let saved = try? JSONDecoder().decode([UIContext.MenuItem].self, from: data) { items = saved }
                self?.shortcutsCard.show(appName: target.localizedName ?? "App", icon: target.icon, items: items)
            }
        }
        // --history opens History.
        if arguments.contains("--history") {
            history.add(.init(question: "how do I crop this", answer: "Choose Tools, then Crop, or press Command K after selecting an area.", app: "Preview", typed: false))
            history.add(.init(question: "what's a good substitute for buttermilk", answer: "Mix a cup of milk with a tablespoon of lemon juice and let it sit for five minutes.", app: "Safari", typed: true))
            showHistory()
        }
        // --magnify shows the closer look around the screen's centre.
        if arguments.contains("--magnify") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, let screen = NSScreen.main else { return }
                _ = await self.magnifier.show(around: NSPoint(x: screen.frame.midX, y: screen.frame.midY), privateApps: [])
            }
        }
        // --timer-demo starts a silent 5-minute timer (review the menu bar countdown).
        if arguments.contains("--timer-demo") { _ = handleTimer(.set(seconds: 300, label: nil)) }
        // --draw=<shape> draws a built-in shape around the screen's centre (review the drawing; nothing is spoken).
        if let arg = arguments.first(where: { $0.hasPrefix("--draw=") }), let shape = Drawing.Shape(rawValue: String(arg.dropFirst(7))) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.drawShape(shape)
            }
        }
        // --sketch=<file> draws a saved sketch (stroke lines) around the screen's centre (review; nothing is sent or spoken).
        if let arg = arguments.first(where: { $0.hasPrefix("--sketch=") }),
           let text = try? String(contentsOfFile: String(arg.dropFirst(9)), encoding: .utf8) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                self.beginSketch()
                if let screen = NSScreen.main { self.sketchFrame.center = Vec2(screen.frame.midX, screen.frame.midY) }
                for line in text.split(separator: "\n") { if let p = Drawing.parseStroke(String(line)) { self.drawSketchStroke(p) } }
            }
        }
        // --sketch-ai=<subject> asks the AI to sketch it and draws it, as "draw a cat" does (review; nothing is spoken).
        if let arg = arguments.first(where: { $0.hasPrefix("--sketch-ai=") }) {
            let subject = String(arg.dropFirst(12))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                let t0 = ProcessInfo.processInfo.systemUptime
                let drawn = await self.pipeline.reviewSketch(subject)
                Log.app.info("debug sketch: \(drawn, privacy: .public) strokes in \(Int(ProcessInfo.processInfo.systemUptime - t0), privacy: .public) s")
            }
        }
        // --web=search:<query> / --web=open:<site words> runs a browser action (review the steps; nothing is spoken).
        if let arg = arguments.first(where: { $0.hasPrefix("--web=") }) {
            let spec = String(arg.dropFirst(6))
            let question = spec.hasPrefix("open:") ? "open " + spec.dropFirst(5)
                : spec.hasPrefix("say:") ? String(spec.dropFirst(4)) : "search online for " + spec.replacingOccurrences(of: "search:", with: "")
            if WebAction.parse(question) == nil, let appAction = AppAction.parse(question) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self else { return }
                    self.overlay.setMode(.thinking)
                    let result = await self.appActor.run(appAction)
                    Log.app.info("debug app action: \(result, privacy: .public)")
                    try? await Task.sleep(for: .seconds(1))
                    self.overlay.setMode(.hidden)
                }
            } else if let action = WebAction.parse(question) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self else { return }
                    self.overlay.setMode(.thinking)
                    _ = await self.webActor.run(action)
                    try? await Task.sleep(for: .seconds(1))
                    self.overlay.setMode(.hidden)
                }
            }
        }
        // --whats-new shows the What's New window with every entry.
        if arguments.contains("--whats-new") { showWhatsNew(WhatsNew.entries) }
        // --ask-box shows the question box (review its look; nothing is captured or sent). --ask-box=<text> types text.
        if let arg = arguments.first(where: { $0.hasPrefix("--ask-box") }) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.askBox.show(hint: "return to ask  ·  esc to close")
                if let eq = arg.firstIndex(of: "=") { self?.askBox.setText(String(arg[arg.index(after: eq)...])) }
            }
        }
        #else
        let debugStep = false
        #endif
        if !app.config.onboardingCompleted || resume || forceOnboarding {
            showOnboarding(resume: resume || debugStep)
        } else if !snapshot.allGranted {
            // A permission that used to work is off now (revoked, or the monthly screen consent lapsed).
            recovery.show()
        }
        observeWake()
        restorePause()
        restoreTimers()
        showWhatsNewAfterUpdate()
        // Models install in the background from the very first launch (onboarding shows progress).
        if let models {
            // Load each speech model as soon as it is installed and verified (warm-up makes first use fast).
            let stt = pipeline.stt
            models.registerWarmer(runtime: "moonshine-ort") { dir, _ in
                try await Task.detached(priority: .utility) { try stt.load(directory: dir) }.value
            }
            let kokoro = self.kokoro
            let savedVoice = app.config.speech.voiceID
            desiredVoice.withLock { $0 = savedVoice }
            let desired = desiredVoice
            models.registerWarmer(runtime: "kokoro-coreml") { [voiceQueue] dir, _ in
                try await Task.detached(priority: .utility) { try kokoro.load(directory: dir) }.value
                // On the voice queue like every other change, using the choice now (not the one at launch).
                voiceQueue.async { kokoro.selectVoice(desired.withLock { $0 }) }
            }
            models.registerWarmer(runtime: "kokoro-voices") { [voiceQueue] dir, _ in
                kokoro.extraVoicesDirectory = dir
                voiceQueue.async { if kokoro.isReady { kokoro.selectVoice(desired.withLock { $0 }) } }
            }
            models.willRemove = { [pipeline, kokoro] model in
                if model.runtime == "moonshine-ort" { pipeline.stt.unload() }
                if model.runtime == "kokoro-coreml" { kokoro.unload() }
            }
            models.start()
        }
        turns.startIfPossible()
        ScreenText.warmUp()
        runDemoScriptIfRequested()
        // Start the hotkey as soon as Input Monitoring is granted; apply settings changes live.
        // Settings and VoiceOver both change the effective chord; apply either live.
        configObservation = app.$config.dropFirst().map { _ in () }
            .merge(with: app.$voiceOverRunning.dropFirst().map { _ in () })
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.turns.configurationChanged()
                    if self.turns.isPaused { self.turns.hotkey.setDoubleTapEnabled(false) }
                    self.captions.enabled = self.app.config.speech.effectiveShowCaptions
                    self.captions.scale = self.app.config.speech.captionScale
                    self.captions.atBottom = self.app.config.speech.captionPosition == "bottom"
                    if TimingLog.shared.enabled != self.app.config.privacy.localTimingLog {
                        TimingLog.shared.setEnabled(self.app.config.privacy.localTimingLog)
                    }
                    self.kokoro.speed = Float(self.app.config.speech.rate)
                    self.kokoro.volume = Float(self.app.config.speech.effectiveVolume)
                    self.applySystemVoice()
                    let id = self.app.config.speech.voiceID
                    if self.desiredVoice.withLock({ $0 }) != id {
                        self.desiredVoice.withLock { $0 = id }
                        // Parsing a voice pack takes a moment: off the main thread, in order, always the latest choice.
                        let kokoro = self.kokoro, desired = self.desiredVoice
                        self.voiceQueue.async { if kokoro.isReady { kokoro.selectVoice(desired.withLock { $0 }) } }
                    }
                    self.overlay.apply(self.app.config.overlay)
                }
            }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.turns.hotkey.cancelCurrent() }
        }
        permissionObservation = app.permissions.$snapshot.sink { [weak self] snapshot in
            if snapshot[.inputMonitoring] == .granted {
                DispatchQueue.main.async { self?.turns.startIfPossible() }
            }
        }
    }

    private var permissionObservation: AnyCancellable?

    // MARK: Windows

    /// Setup from the very start (welcome animation first), even if a setup window is already open.
    public func replayWelcome() {
        if let onboardingWindow {
            onboardingWindow.close()
            self.onboardingWindow = nil
        }
        UserDefaults.standard.removeObject(forKey: "wisp.onboarding.step")
        showOnboarding(resume: false)
    }

    public func showOnboarding(resume: Bool) {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let model = OnboardingModel(resume: resume)
        let view = OnboardingView(model: model, app: app, models: models)
        let hosting = NSHostingController(rootView: view)
        // Fixed size: steps must not resize the window as the user moves through them.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height))
        window.title = "Welcome to Wisp"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        model.onFinish = { [weak self, weak window] in
            window?.close()
            self?.onboardingWindow = nil
        }
        observeClose(of: window) { [weak self] in
            self?.onboardingWindow = nil
            self?.app.permissions.stopPolling(owner: "onboarding")
            // SwiftUI's onDisappear isn't guaranteed on window close: never leave real holds treated as practice.
            self?.app.keys.isPracticing = false
            self?.app.keys.cancelRecording()
        }
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Once after an update: what changed since the version this Mac last ran. (Versions before 0.3.8 didn't record
    /// it, so an existing setup without a record counts as coming from 0.3.2.)
    private func showWhatsNewAfterUpdate() {
        let key = "wisp.whatsNew.lastSeen"
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard !current.isEmpty else { return }
        let last = UserDefaults.standard.string(forKey: key) ?? (app.config.onboardingCompleted ? "0.3.2" : current)
        UserDefaults.standard.set(current, forKey: key)
        let news = WhatsNew.since(last, upTo: current)
        guard !news.isEmpty, app.config.onboardingCompleted else { return }
        showWhatsNew(news)
    }

    // MARK: Drawing

    /// The companion draws `shape` stroke by stroke, centred on the pointer (kept on screen).
    private func drawShape(_ shape: Drawing.Shape) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let size = min(170, v.height * 0.2)
        let cx = min(max(mouse.x, v.minX + size + 20), v.maxX - size - 20)
        let cy = min(max(mouse.y, v.minY + size + 20), v.maxY - size - 20)
        for stroke in Drawing.strokes(shape) {
            let points = stroke.map { Vec2(cx + $0.x * size, cy + $0.y * size) }
            let length = TracePath(kind: .freehand, points: points).length
            overlay.perform(.trace(TracePath(kind: .freehand, points: points, duration: Drawing.duration(forLength: length)), label: ""))
        }
    }

    /// Where the current sketch goes: centred on the pointer, kept on screen.
    private var sketchFrame: (center: Vec2, size: Double) = (Vec2(0, 0), 150)

    private func beginSketch() {
        overlay.clearDrawings()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let size = min(210, v.height * 0.26)
        sketchFrame = (Vec2(min(max(mouse.x, v.minX + size + 20), v.maxX - size - 20),
                            min(max(mouse.y, v.minY + size + 20), v.maxY - size - 20)), size)
    }

    /// One stroke of a sketch (100 × 100 box, y down) drawn by the companion.
    private func drawSketchStroke(_ points: [Vec2]) {
        let (c, size) = sketchFrame
        let mapped = points.map { Vec2(c.x + ($0.x - 50) / 50 * size, c.y + (50 - $0.y) / 50 * size) }
        let length = TracePath(kind: .freehand, points: mapped).length
        overlay.perform(.trace(TracePath(kind: .freehand, points: mapped, duration: Drawing.duration(forLength: length)), label: ""))
    }

    // MARK: Timers and reminders

    private struct ActiveTimer {
        var id = UUID()
        var fires: Date
        var label: String?
        var timer: Timer
    }
    private var timers: [ActiveTimer] = []
    /// The timer or reminder that went off last (for "snooze").
    private var lastFired: (label: String?, at: Date)?
    private var notes = Notes()
    private static var notesURL: URL { AppPaths.applicationSupport.appendingPathComponent("notes.json") }

    private func handleNotes(_ command: Notes.Command) -> String {
        switch command {
        case .add(let text):
            notes.add(text)
            try? notes.save(to: Self.notesURL)
            app.notesCount = notes.items.count
            return "Okay, I'll remember that \(text)."
        case .list:
            if notes.items.count > 1 {
                answerCard.show(question: "Your notes", answer: notes.items.reversed().map { "• \($0.text)" }.joined(separator: "\n"), near: nil)
            }
            return notes.spoken
        case .forget(let topic):
            guard let removed = notes.forget(topic) else { return "I don't have a note about \(topic)." }
            try? notes.save(to: Self.notesURL)
            app.notesCount = notes.items.count
            return "Okay, I've forgotten that \(removed.text)."
        case .clear:
            let had = !notes.items.isEmpty
            notes.clear()
            try? FileManager.default.removeItem(at: Self.notesURL)
            app.notesCount = 0
            return had ? "Done. I've forgotten your notes." : "There were no notes to forget."
        }
    }

    private func handleTimer(_ command: TimerCommand) -> String {
        let now = Date()
        switch command {
        case .set(let seconds, let label):
            guard seconds >= 1, seconds <= 24 * 3600 else { return "I can set timers from a second up to a day." }
            schedule(at: now.addingTimeInterval(seconds), label: label)
            if let label { return "Okay, I'll remind you to \(label) in \(TimerCommand.spoken(seconds))." }
            return "Timer set for \(TimerCommand.spoken(seconds))."
        case .at(let hour, let minute, let label):
            let date = TimerCommand.nextDate(hour: hour, minute: minute, after: now)
            schedule(at: date, label: label)
            let time = date.formatted(date: .omitted, time: .shortened)
            let day = Calendar.current.isDateInToday(date) ? "" : " tomorrow"
            return "Okay, I'll remind you\(day) at \(time)" + (label.map { " to \($0)." } ?? ".")
        case .cancel:
            guard !timers.isEmpty else { return "You don't have any timers or reminders." }
            let count = timers.count
            timers.forEach { $0.timer.invalidate() }
            timers.removeAll()
            updateCountdown()
            saveTimers()
            return count == 1 ? "Cancelled." : "Cancelled all \(count)."
        case .snooze(let seconds):
            guard let last = lastFired else { return "There's nothing to snooze right now." }
            schedule(at: now.addingTimeInterval(seconds), label: last.label)
            answerCard.hide()
            return "Okay, again in \(TimerCommand.spoken(seconds))."
        case .extend(let seconds):
            guard let index = timers.indices.min(by: { timers[$0].fires < timers[$1].fires }) else { return "You don't have a timer running." }
            let old = timers.remove(at: index)
            old.timer.invalidate()
            schedule(at: old.fires.addingTimeInterval(seconds), label: old.label)
            return "Added \(TimerCommand.spoken(seconds)). \(TimerCommand.spoken(old.fires.addingTimeInterval(seconds).timeIntervalSinceNow)) left."
        case .status:
            guard let next = timers.min(by: { $0.fires < $1.fires }) else { return "You don't have any timers running." }
            let left = TimerCommand.spoken(next.fires.timeIntervalSinceNow)
            return next.label.map { "\(left) until I remind you to \($0)." } ?? "\(left) left on your timer."
        }
    }

    private var countdownTimer: Timer?
    private static let timersKey = "wisp.timers"

    /// Timers and reminders are kept across restarts (and updates); ones that came due meanwhile fire right away.
    private func saveTimers() {
        let list = timers.map { ["fires": $0.fires.timeIntervalSince1970, "label": $0.label ?? ""] as [String: Any] }
        UserDefaults.standard.set(list, forKey: Self.timersKey)
    }

    private func restoreTimers() {
        guard timers.isEmpty, let list = UserDefaults.standard.array(forKey: Self.timersKey) as? [[String: Any]] else { return }
        for item in list {
            guard let t = item["fires"] as? Double else { continue }
            let label = (item["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            schedule(at: max(Date(timeIntervalSince1970: t), Date().addingTimeInterval(2)), label: label)
        }
    }

    /// Shows the nearest timer (not reminders set for a clock time far away) counting down in the menu bar.
    private func updateCountdown() {
        guard let next = timers.min(by: { $0.fires < $1.fires }), next.fires.timeIntervalSinceNow < 3600 else {
            statusItem.countdown = nil
            if timers.isEmpty { countdownTimer?.invalidate(); countdownTimer = nil }
            return
        }
        let left = max(0, Int(next.fires.timeIntervalSinceNow.rounded(.up)))
        statusItem.countdown = String(format: "%d:%02d", left / 60, left % 60)
        if countdownTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateCountdown() } }
            RunLoop.main.add(t, forMode: .common)
            countdownTimer = t
        }
    }

    private func schedule(at date: Date, label: String?) {
        let id = UUID()
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(ActiveTimer(id: id, fires: date, label: label, timer: timer))
        updateCountdown()
        saveTimers()
    }

    private func timerFired(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        let fired = timers.remove(at: index)
        lastFired = (fired.label, Date())
        updateCountdown()
        saveTimers()
        let text = fired.label.map { "Reminder: \($0)." } ?? "Time's up! Your timer is done."
        NSSound(named: "Glass")?.play()
        if isIdle && !turns.isPaused { pipeline.speakAgain([text]) }
        answerCard.show(question: fired.label == nil ? "Timer" : "Reminder", answer: text, near: nil)
    }

    private func timerMenuItems() -> [NSMenuItem] {
        guard !timers.isEmpty else { return [] }
        var items: [NSMenuItem] = []
        for t in timers.sorted(by: { $0.fires < $1.fires }) {
            let when = t.fires.timeIntervalSinceNow < 3600 ? TimerCommand.spoken(max(0, t.fires.timeIntervalSinceNow)) + " left"
                                                           : t.fires.formatted(date: .omitted, time: .shortened)
            let item = NSMenuItem(title: t.label.map { "\(when): \($0)" } ?? "Timer: \(when)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: t.label == nil ? "timer" : "bell", accessibilityDescription: nil)
            items.append(item)
        }
        items.append(MenuAction.item(timers.count == 1 ? "Cancel Timer" : "Cancel All Timers") { [weak self] in
            _ = self?.handleTimer(.cancel)
        })
        return items
    }

    // MARK: History

    private func recordHistory(question: String, answer: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front?.localizedName
        history.add(History.Entry(question: question, answer: answer, app: appName, typed: typedTurnActive))
        historyChanged()
    }

    private func historyChanged() {
        historyModel?.history = history
        if app.config.privacy.keepHistory { try? history.save(to: Self.historyURL) }
    }

    public func showHistory() {
        if let historyWindow { historyWindow.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let model = HistoryModel()
        model.history = history
        model.keep = app.config.privacy.keepHistory
        model.onSayAgain = { [weak self] entry in self?.pipeline.speakAgain(SentenceSplitter.split(entry.answer)) }
        model.onChange = { [weak self] updated in
            self?.history = updated
            self?.historyChanged()
        }
        model.onKeepChanged = { [weak self] keep in
            guard let self else { return }
            self.app.update { $0.privacy.keepHistory = keep }
            if keep { try? self.history.save(to: Self.historyURL) } else { try? FileManager.default.removeItem(at: Self.historyURL) }
        }
        historyModel = model
        let window = EscapeClosingWindow(contentViewController: NSHostingController(rootView: HistoryView(model: model)))
        window.title = "Wisp History"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(HistoryView.size)
        window.center()
        observeClose(of: window) { [weak self] in self?.historyWindow = nil }
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Shortcuts card

    /// Menu > Keyboard Shortcuts…: the shortcuts of the app that was in front when the menu opened.
    public func showShortcutsForFrontApp() {
        guard UIContextReader.isAllowed else {
            pipeline.showCaption("To list an app's shortcuts, turn on Better answers in Wisp Settings > Permissions.", seconds: 3.5)
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.config.privacy.privateApps.contains(front.bundleIdentifier ?? "") else { return }
        let pid = front.processIdentifier
        let name = front.localizedName ?? "This app"
        Task { @MainActor [weak self] in
            let items = await Task.detached(priority: .userInitiated, operation: { UIContextReader.menuShortcuts(pid: pid) }).value
            self?.shortcutsCard.show(appName: name, icon: front.icon, items: items)
        }
    }

    // MARK: Check-up

    public func showCheckup() {
        if let checkupWindow { checkupWindow.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let model = CheckupModel()
        model.runChecks = { [weak self] model in await self?.runCheckup(model) }
        model.report = { [weak self, weak model] in
            guard let self, let model else { return "" }
            var lines = [self.app.permissions.diagnostics(), "Model: \(self.app.config.vision.modelID)"]
            // The last 30 questions' outcomes and timing (content-free), for remote help.
            let recentTurns = Array(TimingLog.shared.load().suffix(30))
            if !recentTurns.isEmpty {
                var counts: [String: Int] = [:]
                recentTurns.forEach { counts[$0.outcome, default: 0] += 1 }
                lines.append("Last \(recentTurns.count) questions: " + counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                if let ms = UsageStats.from(recentTurns).medianStartMs { lines.append("Typical start: \(ms) ms after key-up") }
            }
            for row in model.rows {
                switch row.status {
                case .ok(let s): lines.append("OK: \(row.title): \(s)")
                case .problem(let s): lines.append("PROBLEM: \(row.title): \(s)")
                case .optional(let s): lines.append("Optional: \(row.title): \(s)")
                case .checking: lines.append("…: \(row.title)")
                }
            }
            return lines.joined(separator: "\n")
        }
        let window = EscapeClosingWindow(contentViewController: NSHostingController(rootView: CheckupView(model: model)))
        window.title = "Wisp Check-up"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(CheckupView.size)
        window.center()
        observeClose(of: window) { [weak self] in self?.checkupWindow = nil }
        checkupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func runCheckup(_ model: CheckupModel) async {
        let snapshot = app.permissions.refresh()
        var rows: [CheckupModel.Row] = []
        let perm: [(PermissionKind, String, String, String)] = [
            (.microphone, "mic", "Microphone", "Wisp can't hear your question."),
            (.screenRecording, "rectangle.dashed", "Seeing your screen", "Wisp can't see what you're asking about."),
            (.inputMonitoring, "keyboard", "Noticing your shortcut", "Wisp can't tell when you hold the shortcut."),
        ]
        for (kind, symbol, title, why) in perm {
            let ok = snapshot[kind].isUsable
            rows.append(.init(id: kind.rawValue, symbol: symbol, title: title,
                              status: ok ? .ok("Allowed.") : .problem("Off. \(why)"),
                              fix: ok ? nil : .init(title: "Fix…") { [weak self] in self?.recovery.show(for: [kind]) }))
        }
        let chord = app.effectiveChord
        let hotkeyOK = turns.hotkey.status == .running
        rows.append(.init(id: "shortcut", symbol: "command", title: "Shortcut",
                          status: hotkeyOK ? .ok("\(chord.mode == .hold ? "Hold" : "Press") \(chord.modifiers.names) to ask\(turns.isPaused ? " (Wisp is paused)" : "").")
                                           : .problem("Not listening for the shortcut yet."),
                          fix: turns.isPaused ? .init(title: "Resume") { [weak self] in self?.pause(until: nil) } : nil))
        let speech = models?.speechProblem
        rows.append(.init(id: "speech", symbol: "waveform", title: "Understanding speech",
                          status: speech == nil ? .ok("Ready, on this Mac.") : .problem(speech!),
                          fix: speech == nil ? nil : .init(title: "Open…") { [weak self] in self?.showSettings(tab: "models") }))
        rows.append(.init(id: "voice", symbol: "speaker.wave.2", title: "Wisp's voice",
                          status: kokoro.isReady ? .ok("Ready, on this Mac.")
                                                 : .optional("Still getting ready; the Mac's own voice speaks until then."),
                          fix: nil))
        let connected = APIKeyStore.isConnected(app.config.vision)
        rows.append(.init(id: "ai", symbol: "sparkles", title: "AI service (\(app.config.vision.providerDisplayName))",
                          status: connected ? .checking : .problem("Not connected yet."),
                          fix: connected ? nil : .init(title: "Connect…") { [weak self] in self?.showSettings(tab: "ai") }))
        let details = app.config.vision.readAppControls && UIContextReader.isAllowed
        rows.append(.init(id: "details", symbol: "list.bullet.rectangle", title: "Better answers",
                          status: details ? .ok("On: Wisp reads the app's buttons, menus and selected text.")
                                          : .optional("Off (optional). Turn it on for more accurate answers."),
                          fix: details ? nil : .init(title: "Turn On…") { [weak self] in
                              UIContextReader.requestAccess()
                              self?.showSettings(tab: "permissions")
                          }))
        let privateCount = app.config.privacy.privateApps.count
        let privacyText = [privateCount == 0 ? "No private apps" : "\(privateCount) private app\(privateCount == 1 ? "" : "s")",
                           app.config.privacy.keepHistory ? "History saved on this Mac" : "History kept until Wisp quits",
                           app.notesCount == 0 ? "no notes" : "\(app.notesCount) note\(app.notesCount == 1 ? "" : "s")"].joined(separator: " · ")
        rows.append(.init(id: "privacy", symbol: "hand.raised", title: "Privacy", status: .ok(privacyText + "."),
                          fix: .init(title: "Open…") { [weak self] in self?.showSettings(tab: "privacy") }))
        let updates = updater?.isConfigured == true
        rows.append(.init(id: "updates", symbol: "arrow.down.circle", title: "Updates",
                          status: updates ? .ok("Wisp checks for updates by itself.") : .optional("This copy doesn't update itself."),
                          fix: nil))
        model.rows = rows
        guard connected else { return }
        let result = await VisionConnectionTest.run(config: app.config.vision, provider: VisionProvider(configID: app.config.vision.providerID))
        switch result {
        case .ok(let message): model.set("ai", .ok(message))
        case .failed(let message):
            model.set("ai", .problem(message), fix: .init(title: "Open…") { [weak self] in self?.showSettings(tab: "ai") })
        case .rejectedKey:
            model.set("ai", .problem("The service didn't accept the key."), fix: .init(title: "Open…") { [weak self] in self?.showSettings(tab: "ai") })
        case .idle, .running: break
        }
    }

    public func showWhatsNew(_ entries: [WhatsNew.Entry]) {
        whatsNewWindow?.close()
        let window = EscapeClosingWindow(contentViewController: NSHostingController(rootView: WhatsNewView(entries: entries, onClose: { [weak self] in
            self?.whatsNewWindow?.close()
        })))
        window.title = "What's New in Wisp"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(WhatsNewView.size)
        window.center()
        observeClose(of: window) { [weak self] in self?.whatsNewWindow = nil }
        whatsNewWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func makeModelManager(app: AppState) -> ModelManager? {
        do {
            let manifest = try ModelManager.bundledManifest()
            // In-process session: background sessions from a menu-bar (LSUIElement) app are scheduled as
            // discretionary by nsurlsessiond (observed: crawled for 10+ minutes). Partial downloads are kept
            // as resume data on quit (`prepareForQuit`) and continue on the next launch.
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpMaximumConnectionsPerHost = 4
            let session = DownloadSession(configuration: config, holdingDirectory: AppPaths.caches.appendingPathComponent("model-downloads"))
            let policy = ConsentPolicyGate(disclosureAccepted: { true })
            let deps = ModelManager.Dependencies(root: AppPaths.models, session: session, policy: policy,
                                                 settings: { [weak app] in MainActor.assumeIsolated { app?.config.models ?? ModelSourceSettings() } })
            return ModelManager(manifest: manifest, dependencies: deps)
        } catch {
            Log.models.error("model manifest unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Call from `applicationWillTerminate`.
    public func prepareForQuit() {
        models?.prepareForQuit()
    }

    /// Stops whatever Wisp is doing (menu > Stop): listening, thinking or speaking.
    public func stopTurn() {
        endGuide()
        answerCard.hide()
        turns.stopCurrentTurn()
        pipeline.stopSpeaking()
        overlay.clearDrawings()
    }

    /// Not listening, thinking or speaking: a safe moment to restart for an update.
    public var isIdle: Bool { turns.phase == .idle && !pipeline.isSpeaking }

    /// True when a regular window (settings or onboarding) is open; the recovery card doesn't count.
    public var hasOpenWindow: Bool { settingsWindow?.isVisible == true || onboardingWindow?.isVisible == true }

    /// Opens Settings, optionally on a given tab ("general", "models", "ai", "companion", "permissions", "privacy", "about").
    public func showSettings(tab: String? = nil) {
        if let tab { settingsNavigation.tab = tab }
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: app, nav: settingsNavigation, extraTabs: settingsTabs, updater: updater)))
        window.title = "Wisp Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        observeClose(of: window) { [weak self] in
            self?.settingsWindow = nil
            self?.app.permissions.stopPolling(owner: "settings")
            self?.app.keys.cancelRecording()
        }
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Runs `onClose` once when `window` closes, then removes the observer (no leaked tokens).
    private func observeClose(of window: NSWindow, _ onClose: @escaping @MainActor () -> Void) {
        let key = ObjectIdentifier(window)
        windowObservers[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                onClose()
                if let token = self?.windowObservers.removeValue(forKey: key) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
    }

    /// Debug builds: `WISP_DEMO_SCRIPT=1` loops a scripted turn (listen → think → answer → home) on the
    /// overlay without touching the microphone, keyboard or pointer, for visual checks.
    private func runDemoScriptIfRequested() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WISP_DEMO_SCRIPT"] == "2" { runGestureDemo(); return }
        guard ProcessInfo.processInfo.environment["WISP_DEMO_SCRIPT"] == "1" else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            while let self {
                self.overlay.setMode(.listening)
                for i in 0..<40 {
                    self.overlay.setLevel(Float(0.35 + 0.35 * sin(Double(i) * 0.7) + 0.2 * sin(Double(i) * 2.3)))
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self.overlay.setLevel(0)
                self.overlay.setMode(.thinking)
                try? await Task.sleep(for: .seconds(1.5))
                self.overlay.setMode(.resting)
                try? await Task.sleep(for: .seconds(1.0))
                self.overlay.setMode(.hidden)
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
        #endif
    }

    /// Debug: performs every gesture kind around the screen centre (no microphone, keyboard or pointer use).
    private func runGestureDemo() {
        #if DEBUG
        Task { @MainActor [weak self] in
            guard let self, let screen = NSScreen.main else { return }
            let c = Vec2(screen.frame.midX, screen.frame.midY)
            try? await Task.sleep(for: .seconds(1))
            self.overlay.setMode(.resting)
            try? await Task.sleep(for: .seconds(0.8))
            self.overlay.perform(.point(at: c + Vec2(-300, 150), label: "Export"))
            try? await Task.sleep(for: .seconds(1.4))
            self.overlay.perform(.trace(GesturePlanner.circle(around: Rect(x: c.x - 80, y: c.y - 20, width: 160, height: 40)), label: "Save"))
            try? await Task.sleep(for: .seconds(1.8))
            self.overlay.perform(.trace(GesturePlanner.underline(from: c + Vec2(-120, -140), to: c + Vec2(140, -140)), label: "Title"))
            try? await Task.sleep(for: .seconds(1.4))
            self.overlay.perform(.trace(GesturePlanner.arrow(from: c + Vec2(260, -60), to: c + Vec2(120, 0)), label: "Here"))
            try? await Task.sleep(for: .seconds(1.8))
            self.overlay.setMode(.hidden)
        }
        #endif
    }

    // MARK: Typed questions

    /// Opens the question box (or closes it if open). The screenshot is taken first, so the box is never in it.
    public func askByTyping() {
        if askBox.isVisible { askBox.close(); return }
        suspendGuide()
        lastTarget = nil
        guard app.config.onboardingCompleted else { return }
        let id = turns.beginTypedTurn()
        answerCard.hide()
        askBox.onAsk = { [weak self, turns] text in
            self?.typedTurnActive = true
            turns.submitTypedTurn(id, question: text)
        }
        askBox.onAskSilently = { [weak self, turns] text in
            self?.typedTurnActive = true
            turns.submitTypedTurn(id, question: text, silent: true)
        }
        askBox.onCancel = { [turns] in turns.cancelTypedTurn(id) }
        askBox.show(hint: "return to ask  ·  ⌘ return: silent  ·  esc")
    }

    // MARK: Pause

    private static let pauseKey = "wisp.pausedUntil"
    private var pauseTimer: Timer?

    /// Pauses until `date` (nil resumes). Remembered across restarts; resumes by itself when the time comes.
    public func pause(until date: Date?) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        let active = date.map { $0 > Date() } ?? false
        if active, let date {
            stopTurn()
            if askBox.isVisible { askBox.close() }
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.pauseKey)
            if date != .distantFuture {
                pauseTimer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pause(until: nil) }
                }
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pauseKey)
        }
        turns.isPaused = active
        statusItem.pausedUntil = active ? date : nil
        turns.hotkey.setDoubleTapEnabled(!active && app.config.typeToAsk && app.effectiveChord.modifiers != app.config.typeKeyModifier)
    }

    private func restorePause() {
        let saved = UserDefaults.standard.double(forKey: Self.pauseKey)
        guard saved > 0 else { return }
        pause(until: Date(timeIntervalSince1970: saved))
    }

    // MARK: Step-by-step guidance

    private var guide: GuideSession?
    private var appActivationObserver: NSObjectProtocol?
    /// Where the current answer last pointed (AppKit global) and the label.
    private var lastTarget: (Vec2, String)?
    /// The STEPS line of the answer that just finished (nil: it had none).
    private var lastStepsMore: Bool?
    private var guideMonitors: [Any] = []
    private var guideStepRunning = false
    private var guideGeneration = 0
    /// The screen as it looked when the current step was given, to tell a real step from a stray click.
    private var guideBaseline: ScreenFingerprint?
    /// They did something while Wisp was working out the next step (look again as soon as it's given).
    private var actedDuringStep = false
    private var lastGuideInput: TimeInterval = 0
    private var guideQuietNeeded: TimeInterval = 0.8
    private var settleTask: Task<Void, Never>?
    /// They're asking Wisp something mid-walkthrough: clicks are noted but don't move it on until that's answered.
    private var guideSuspended = false
    /// Repeats of a step they already did that were skipped (only the first is; a second is said).
    private var guideRepeatsSkipped = 0
    private var guideTimeoutTask: Task<Void, Never>?

    private func noteTarget(_ event: AssistantEvent, record: CaptureRecord, space: ModelCoordinateSpace) {
        switch event {
        case .point(let x, let y, let label):
            if let p = record.globalPoint(fromModel: x, y, space: space) { lastTarget = (p, label ?? "") }
        case .circle(let x, let y, let w, let h, let label):
            if let p = record.globalPoint(fromModel: x + w / 2, y + h / 2, space: space) { lastTarget = (p, label ?? "") }
        default: break
        }
    }

    /// An answer finished: start a walkthrough after a how-to answer with more steps to come, or move one on.
    private func answerFinished(question: String, answer: [String]) {
        let target = lastTarget
        let more = lastStepsMore
        lastTarget = nil
        lastStepsMore = nil
        let said = answer.joined(separator: " ")
        if guideStepRunning {
            guideStepRunning = false
            guard var g = guide else { return }
            // Finished: the model says so (or, without a STEPS line, has nothing more to show), or the limit is reached.
            if more == false || (more == nil && target == nil) || g.isAtLimit {
                endGuide()
                return
            }
            g.advance(said: said, target: target?.0, targetLabel: target?.1 ?? "")
            guide = g
            guideRepeatsSkipped = 0
            watchForNextStep()
            return
        }
        // A new question during a walkthrough (not "what now?", which was answered as the next step) ends it.
        if guide != nil { endGuide() }
        guard app.config.guideSteps, GuideSession.isTask(question) else { return }
        // More steps to come (or, from a model that gave no STEPS line, a how-to answer that pointed somewhere).
        guard more == true || (more == nil && target != nil) else { return }
        guide = GuideSession(goal: question, said: said, target: target?.0, targetLabel: target?.1 ?? "")
        pipeline.showCaption("Go ahead, I'll watch and tell you the next step. Esc stops.", seconds: 3.5)
        watchForNextStep()
    }

    /// Watches for them to do the current step: remembers how the screen looks now and listens for clicks and keys.
    private func watchForNextStep() {
        guideSuspended = false
        guideGeneration += 1
        let generation = guideGeneration
        settleTask?.cancel()
        settleTask = nil
        guideBaseline = nil
        installGuideMonitors()
        armGuideTimeout()
        let capturer = pipeline.capturer
        let point = NSEvent.mouseLocation
        let acted = actedDuringStep
        actedDuringStep = false
        Task { @MainActor [weak self] in
            let baseline = await capturer.fingerprint(under: point)
            guard let self, self.guideGeneration == generation else { return }
            self.guideBaseline = baseline
            // They already did it while Wisp was talking: look again right away.
            if acted { self.settleThenAsk(force: true) }
        }
    }

    /// The next step would only have repeated the one they just did (the screen hadn't caught up). Say nothing,
    /// and look again as soon as the screen changes (or they do something else).
    private func guideRepeatSkipped() {
        guard guide != nil else { return }
        guideStepRunning = false
        guideRepeatsSkipped += 1
        pipeline.showCaption("Waiting for that to open…", seconds: 3)
        watchForNextStep()
        let generation = guideGeneration
        let capturer = pipeline.capturer
        Task { @MainActor [weak self] in
            // Up to ~10 s for the result of their click to show up.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.guideGeneration == generation, !self.guideStepRunning else { return }
                guard let base = self.guideBaseline else { continue }
                if let now = await capturer.fingerprint(under: NSEvent.mouseLocation), now.changed(from: base) {
                    self.settleThenAsk(force: true)
                    return
                }
            }
        }
    }

    private enum GuideInput { case click(Vec2), key(String), typing }

    private func installGuideMonitors() {
        guard guideMonitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.guideInput(.click(Vec2(location.x, location.y))) }
        }) { guideMonitors.append(m) }
        // Keys (needs the Accessibility permission; without it, clicks alone move the walkthrough on).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let input = Self.guideInput(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            MainActor.assumeIsolated { if let input { self?.guideInput(input) } }
        }) { guideMonitors.append(m) }
    }

    /// A key as a step action: Return, Tab, arrow keys and shortcuts by name; anything else is typing (never which keys).
    private nonisolated static func guideInput(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> GuideInput? {
        switch keyCode {
        case 53: return nil                                    // Escape stops the walkthrough (hotkey monitor)
        case 36, 76: return .key("Return")
        case 48: return .key("Tab")
        case 123, 124, 125, 126: return .key("an arrow key")
        default: break
        }
        let mods = flags.intersection([.command, .control, .option])
        guard !mods.isEmpty else { return .typing }
        var name = ""
        if mods.contains(.control) { name += "Control-" }
        if mods.contains(.option) { name += "Option-" }
        if flags.contains(.shift) { name += "Shift-" }
        if mods.contains(.command) { name += "Command-" }
        let key = (characters ?? "").uppercased()
        return .key(name + (key.isEmpty || key.unicodeScalars.contains(where: { $0.value < 32 }) ? "a key" : key))
    }

    private func guideInput(_ input: GuideInput) {
        guard var g = guide else { return }
        switch input {
        case .click(let point): g.clicked(at: point)
        case .key(let name): g.record(.key(name))
        case .typing: g.record(.typing)
        }
        guide = g
        armGuideTimeout()
        // While the next step is being worked out (or they're asking something), just note it; Wisp looks again after.
        if guideStepRunning || guideSuspended { actedDuringStep = true; return }
        lastGuideInput = ProcessInfo.processInfo.systemUptime
        // Typing: wait until they pause for a moment (they may not be done); a click or shortcut settles quickly.
        if case .typing = input { guideQuietNeeded = 2.0 } else { guideQuietNeeded = 0.8 }
        settleThenAsk(force: false)
    }

    /// Waits until they pause and the screen stops changing (a menu opening, a sheet sliding in, a page loading),
    /// then asks for the next step with a fresh screenshot. A click that changed nothing keeps the current step.
    private func settleThenAsk(force: Bool) {
        settleTask?.cancel()
        let generation = guideGeneration
        let capturer = pipeline.capturer
        settleTask = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled, self.guideGeneration == generation else { return }
                let quiet = ProcessInfo.processInfo.systemUptime - self.lastGuideInput
                if quiet >= self.guideQuietNeeded || force { break }
                try? await Task.sleep(for: .milliseconds(Int((self.guideQuietNeeded - quiet) * 1000) + 20))
            }
            let point = NSEvent.mouseLocation
            var previous = await capturer.fingerprint(under: point)
            var settled = previous
            for _ in 0..<14 {   // up to ~5 s for animations and loading
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                let next = await capturer.fingerprint(under: point)
                settled = next
                if let p = previous, let n = next, !n.changed(from: p) { break }
                previous = next
            }
            guard let self, !Task.isCancelled, self.guideGeneration == generation, !self.guideStepRunning else { return }
            // A click on the highlighted control (or a key) always counts, even if the screen barely changed (a
            // checkbox, a toggle); only a stray click that changed nothing keeps the current step.
            if !force, self.guide?.usedTheStep != true, let base = self.guideBaseline, let now = settled, !now.changed(from: base) {
                Log.app.info("guide: nothing changed on screen; still waiting")
                return
            }
            self.askNextStep()
        }
    }

    /// Asks for the next step: a fresh screenshot, with the goal and what's happened so far.
    private func askNextStep() {
        guard let g = guide, !guideStepRunning else { return }
        guard isIdle else {
            // Still talking (or something else is running): try again shortly.
            let generation = guideGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.guideGeneration == generation else { return }
                self.askNextStep()
            }
            return
        }
        Log.app.info("guide: asking for step \(g.stepNumber + 1, privacy: .public)")
        guideStepRunning = true
        settleTask = nil
        lastTarget = nil
        lastStepsMore = nil
        let generation = guideGeneration
        let id = turns.beginTypedTurn()
        turns.submitTypedTurn(id, question: "What's the next step?", guideText: g.requestText)
        watchStepTurn(generation: generation)
    }

    /// If a next-step turn ends without an answer (no connection, the service failed), don't leave them waiting.
    private func watchStepTurn(generation: Int) {
        Task { @MainActor [weak self] in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.guideGeneration == generation else { return }
                if self.isIdle {
                    if self.guideStepRunning {
                        self.endGuide()
                        self.pipeline.showCaption("I lost track of the steps. Ask me again to pick up where you are.", seconds: 4)
                    }
                    return
                }
            }
        }
    }

    /// They're asking something by voice: stop looking for the step while they talk (the answer decides what's next).
    private func suspendGuide() {
        guard guide != nil else { return }
        settleTask?.cancel()
        settleTask = nil
        guideSuspended = true
        guideGeneration += 1      // drops any pending look; the guide itself stays for "what now?"
        armGuideTimeout()
        // If that turn ends without an answer (nothing said, cancelled), carry on watching for the step.
        let generation = guideGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            while let self, self.guideGeneration == generation, self.guideSuspended {
                if self.isIdle && !self.guideStepRunning {
                    if self.guide != nil { self.watchForNextStep() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Guidance ends by itself if nothing happens for a while (one timer, pushed back by each action).
    private func armGuideTimeout() {
        lastGuideActivity = ProcessInfo.processInfo.systemUptime
        guard guideTimeoutTask == nil else { return }
        guideTimeoutTask = Task { @MainActor [weak self] in
            while let self, self.guide != nil, !Task.isCancelled {
                let left = self.lastGuideActivity + GuideSession.idleTimeout - ProcessInfo.processInfo.systemUptime
                if left <= 0 && self.isIdle && !self.guideStepRunning {
                    Log.app.info("guide: ended after a quiet while")
                    self.endGuide()
                    return
                }
                try? await Task.sleep(for: .seconds(max(1, left)))
            }
            self?.guideTimeoutTask = nil
        }
    }
    private var lastGuideActivity: TimeInterval = 0

    private func endGuide() {
        guideGeneration += 1
        guide = nil
        guideStepRunning = false
        guideSuspended = false
        guideRepeatsSkipped = 0
        guideTimeoutTask?.cancel()
        guideTimeoutTask = nil
        actedDuringStep = false
        guideBaseline = nil
        settleTask?.cancel()
        settleTask = nil
        for monitor in guideMonitors { NSEvent.removeMonitor(monitor) }
        guideMonitors.removeAll()
    }

    /// What the question box offers as you type (the app in front stays in front while the box is open).
    private func quickActions() -> [QuickAction] {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app"
        return [
            QuickAction(id: "summarize", title: "Summarize this page", symbol: "text.append",
                        keywords: ["summary", "gist", "key", "points", "tldr", "article", "email"], kind: .ask("summarize this page")),
            QuickAction(id: "read-selection", title: "Read the selected text aloud", symbol: "text.bubble",
                        keywords: ["speak", "listen", "voice", "selection"], kind: .run { [weak self] in self?.statusItem.onReadSelection?() }),
            QuickAction(id: "read-page", title: "Read this page aloud", symbol: "speaker.wave.2",
                        keywords: ["speak", "listen", "article", "email", "window"], kind: .ask("read this page to me")),
            QuickAction(id: "copy-text", title: "Copy the text on screen", symbol: "text.viewfinder",
                        keywords: ["ocr", "grab", "clipboard", "image", "video"], kind: .run { [weak self] in self?.statusItem.onCopyScreenText?() }),
            QuickAction(id: "shortcuts", title: "Keyboard shortcuts in \(name)", symbol: "command.square",
                        keywords: ["keys", "hotkeys", "commands"], kind: .run { [weak self] in self?.showShortcutsForFrontApp() }),
            QuickAction(id: "timer", title: "Set a timer…", symbol: "timer", keywords: ["alarm", "countdown", "minutes"],
                        kind: .fill("set a timer for ")),
            QuickAction(id: "remind", title: "Remind me…", symbol: "bell", keywords: ["reminder", "later", "remember"],
                        kind: .fill("remind me in ")),
            QuickAction(id: "translate", title: "Translate this page…", symbol: "character.bubble",
                        keywords: ["language", "english", "spanish", "french", "german"], kind: .fill("translate this page into ")),
            QuickAction(id: "polite", title: "Make the selected text more polite", symbol: "wand.and.stars",
                        keywords: ["rewrite", "formal", "email", "message", "nicer"], kind: .ask("make this more polite")),
            QuickAction(id: "explain", title: "Explain the selected text simply", symbol: "lightbulb",
                        keywords: ["meaning", "understand", "simple", "plain"], kind: .ask("explain the selected text in simple words")),
            QuickAction(id: "shorter", title: "Make the selected text shorter", symbol: "arrow.down.right.and.arrow.up.left",
                        keywords: ["shorten", "concise", "trim", "rewrite"], kind: .ask("make this shorter")),
            QuickAction(id: "grammar", title: "Fix the grammar of the selected text", symbol: "checkmark.seal",
                        keywords: ["spelling", "typos", "proofread", "correct"], kind: .ask("fix the grammar")),
            QuickAction(id: "define", title: "Define a word…", symbol: "character.book.closed", keywords: ["dictionary", "meaning", "definition"],
                        kind: .fill("define ")),
            QuickAction(id: "world-time", title: "Time in another city…", symbol: "globe", keywords: ["clock", "timezone", "time"],
                        kind: .fill("what time is it in ")),
            QuickAction(id: "notes", title: "My notes", symbol: "note.text", keywords: ["remember", "remembered"],
                        kind: .ask("what are my notes")),
            QuickAction(id: "retry", title: "Try again with the other model", symbol: "arrow.triangle.2.circlepath",
                        keywords: ["wrong", "second", "opinion", "again"], kind: .ask("try again")),
            QuickAction(id: "storage", title: "How much storage do I have?", symbol: "internaldrive", keywords: ["disk", "space", "full", "battery"],
                        kind: .ask("how much storage do I have left")),
            QuickAction(id: "history", title: "History", symbol: "clock.arrow.circlepath", keywords: ["recent", "answers", "past"],
                        kind: .run { [weak self] in self?.showHistory() }),
            QuickAction(id: "checkup", title: "Check Wisp", symbol: "stethoscope", keywords: ["problem", "help", "fix", "not working"],
                        kind: .run { [weak self] in self?.showCheckup() }),
            QuickAction(id: "pause", title: "Pause Wisp for 1 hour", symbol: "pause.circle", keywords: ["quiet", "stop", "presentation"],
                        kind: .run { [weak self] in self?.pause(until: PauseState.end(of: .hour, from: Date())) }),
            QuickAction(id: "whatsnew", title: "What's New", symbol: "sparkles", keywords: ["update", "features", "news"],
                        kind: .run { [weak self] in self?.showWhatsNew(WhatsNew.entries) }),
        ]
    }

    // MARK: Recent answers

    private func recentAnswerItems() -> [NSMenuItem] {
        guard let last = recent.last else { return [] }
        let again = MenuAction.item("Say Last Answer Again", symbol: "arrow.counterclockwise") { [weak self] in
            self?.pipeline.speakAgain(last.sentences)
        }
        let copy = MenuAction.item("Copy Last Answer", symbol: "doc.on.doc") { [weak self] in self?.copyAnswer(last) }
        let list = NSMenuItem(title: "Recent Questions", action: nil, keyEquivalent: "")
        list.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        let heading = NSMenuItem(title: "Click one to copy its answer", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        sub.addItem(heading)
        for entry in recent.entries {
            let item = MenuAction.item(RecentAnswers.title(for: entry.question)) { [weak self] in self?.copyAnswer(entry) }
            item.toolTip = entry.answer
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let note = NSMenuItem(title: "Kept only until Wisp quits", action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        sub.addItem(MenuAction.item("Clear") { [weak self] in self?.recent.clear() })
        sub.addItem(.separator())
        sub.addItem(MenuAction.item("Show All in History…") { [weak self] in self?.showHistory() })
        list.submenu = sub
        return [again, copy, list]
    }

    private func copyAnswer(_ entry: RecentAnswers.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.answer, forType: .string)
        pipeline.showCaption("Answer copied", seconds: 1.5)
    }

    // MARK: Health

    /// Permission state can change while asleep (for example the monthly screen consent); re-check on wake.
    /// The fallback system voice follows the same Speed and Volume settings as Wisp's own voice.
    private func applySystemVoice() {
        pipeline.systemVoice.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * app.config.speech.rate,
                                                  Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
        pipeline.systemVoice.volume = Float(app.config.speech.effectiveVolume)
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.turns.recorder.prepare() // the audio device may have changed while asleep
                let before = self.app.permissions.snapshot
                let after = self.app.permissions.refresh()
                if !after.revoked(since: before).isEmpty { self.recovery.show() }
            }
        }
    }

}

/// A small info window (What's New, Check-up) that closes with Escape, like a sheet.
final class EscapeClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}
