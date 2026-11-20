import SwiftUI
import WispCore

/// Steps of the first-run flow. Additional steps (speech models, practice) are inserted by later features.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, privacy, models, ai, microphone, shortcut, screen, tryIt, done
}

@MainActor
public final class OnboardingModel: ObservableObject {
    @Published public var step: OnboardingStep
    /// Set by the AI step when a key is saved, so the footer button updates.
    @Published public var aiKeySaved = false
    /// "Open Wisp when you log in" on the last step.
    @Published public var openAtLogin = true
    /// Called when the user finishes or closes the flow.
    public var onFinish: (() -> Void)?

    private static let savedStepKey = "wisp.onboarding.step"

    public init(resume: Bool) {
        let saved = UserDefaults.standard.integer(forKey: Self.savedStepKey)
        step = resume ? (OnboardingStep(rawValue: saved) ?? .welcome) : .welcome
    }

    public func go(to next: OnboardingStep) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) { step = next }
        UserDefaults.standard.set(next.rawValue, forKey: Self.savedStepKey)
    }

    public func advance() {
        if let next = OnboardingStep(rawValue: step.rawValue + 1) { go(to: next) }
    }

    public func back() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) { go(to: previous) }
    }

    public func finish() {
        UserDefaults.standard.removeObject(forKey: Self.savedStepKey)
        onFinish?()
    }
}

public struct OnboardingView: View {
    public static var size: CGSize {
        #if DEBUG
        // WISP_ONBOARDING_HEIGHT=<points>: a taller window to review a whole page in one screenshot.
        if let h = Double(ProcessInfo.processInfo.environment["WISP_ONBOARDING_HEIGHT"] ?? "") { return CGSize(width: 600, height: h) }
        #endif
        return CGSize(width: 600, height: 680)
    }
    static let footerHeight: CGFloat = 68
    @ObservedObject var model: OnboardingModel
    @ObservedObject var app: AppState
    var models: ModelManager?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: OnboardingModel, app: AppState, models: ModelManager? = nil) {
        self.model = model
        self.app = app
        self.models = models
    }

    public var body: some View {
        VStack(spacing: 0) {
            // A page that's ever taller than the window scrolls; the button bar below always stays in view.
            ScrollView(.vertical) {
                ZStack {
                    content
                        .id(model.step)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                  removal: .move(edge: .leading).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: Self.size.height - Self.footerHeight - 36 - 16)
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .clipped()

            footer
                .frame(height: Self.footerHeight)
                .layoutPriority(1)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .tint(WispStyle.accent)
        .onAppear { app.permissions.startPolling(owner: "onboarding") }
        .onDisappear { app.permissions.stopPolling(owner: "onboarding") }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .privacy: PrivacyStep(app: app)
        case .models:
            if let models { ModelsOnboardingStep(models: models) } else { EmptyView() }
        case .ai: AIStep(app: app, model: model)
        case .microphone: PermissionStep(app: app, kind: .microphone, model: model)
        case .shortcut: ShortcutStep(app: app, model: model)
        case .screen: PermissionStep(app: app, kind: .screenRecording, model: model)
        case .tryIt: TryItStep(app: app)
        case .done: DoneStep(app: app, model: model)
        }
    }

    private var footer: some View {
        ZStack {
            StepDots(current: model.step)
            HStack {
                if model.step != .welcome && model.step != .done {
                    Button("Back") { model.back() }
                        .controlSize(.large)
                }
                Spacer()
                primaryButton
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.step {
        case .welcome:
            Button("Get Started") { model.advance() }
                .keyboardShortcut(.defaultAction)
        case .privacy:
            Button("I Understand") {
                app.update { $0.privacy.cloudDisclosureAccepted = true }
                model.advance()
            }
            .keyboardShortcut(.defaultAction)
        case .models:
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
        case .ai:
            Button(model.aiKeySaved || APIKeyStore.isConnected(app.config.vision) ? "Continue" : "Skip for Now") {
                model.advance()
            }
            .keyboardShortcut(.defaultAction)
        case .microphone, .screen:
            let kind: PermissionKind = model.step == .microphone ? .microphone : .screenRecording
            Button(app.permissions.snapshot[kind] == .granted ? "Continue" : "Skip for Now") { model.advance() }
                .keyboardShortcut(.defaultAction)
        case .shortcut:
            Button(app.permissions.snapshot[.inputMonitoring] == .granted ? "Continue" : "Skip for Now") { model.advance() }
                .keyboardShortcut(.defaultAction)
        case .tryIt:
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Start Using Wisp") {
                app.update { $0.onboardingCompleted = true }
                // A helper you summon with a shortcut should be there after a restart (only for an installed copy).
                if model.openAtLogin, LoginItem.isInstalled, !LoginItem.isEnabled { LoginItem.setEnabled(true) }
                model.finish()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct StepDots: View {
    var current: OnboardingStep
    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step == current ? WispStyle.accent : Color.secondary.opacity(0.3))
                    .frame(width: step == current ? 18 : 7, height: 7)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                // The icon comes alive: the orb kicks its squircle into the Trash, then hovers and captions
                // "Hi, I'm Wisp" (Wisp never speaks during setup).
                WelcomeHero(onHello: {})
                    .frame(width: WelcomeHeroView.side, height: WelcomeHeroView.side)
                Text("Meet Wisp").font(.largeTitle.weight(.semibold))
                Text("Hold a shortcut and ask anything, out loud. Wisp answers in a friendly voice, and when it's about your screen, it flies over to show you.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                ExplainerRow(symbol: "keyboard", text: "Use your shortcut and ask, for example \u{201C}Where do I export this as a PDF?\u{201D} or \u{201C}How do I boil an egg?\u{201D}")
                ExplainerRow(symbol: "speaker.wave.2", text: "Wisp answers in a short spoken reply with captions.")
                ExplainerRow(symbol: "cursorarrow.motionlines", text: "A little companion flies over and points at the right button or draws around it. Wisp never clicks or types for you.")
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
            Spacer(minLength: 0)
        }
    }
}

private struct PrivacyStep: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(symbol: "lock.shield",
                       title: "What leaves your Mac",
                       subtitle: "Plainly, before you turn anything on.")
            VStack(alignment: .leading, spacing: 14) {
                ExplainerRow(symbol: "mic", text: "Wisp only listens \(app.effectiveChord.whilePhrase). Your voice is turned into text on this Mac and is never uploaded.")
                ExplainerRow(symbol: "camera.viewfinder", text: "When you use the shortcut, Wisp takes \(app.config.vision.screensSentDescription).")
                ExplainerRow(symbol: "icloud.and.arrow.up", text: "The screenshots and the text of your question are sent to \(app.config.vision.providerDisplayName)'s cloud AI service (\(app.config.vision.modelDisplayName)) to work out the answer. Wisp doesn't store them. \(app.config.vision.providerDisplayName)'s own terms apply to what it receives.")
                ExplainerRow(symbol: "waveform", text: "The spoken answer is generated on this Mac.")
                ExplainerRow(symbol: "list.bullet.rectangle", text: "If you turn on Better answers later, the names and states of the front app's buttons and menu commands go with your question too, plus any text you've selected. Never passwords, and typed text only if you select it.")
                ExplainerRow(symbol: "arrow.down.circle", text: "On first launch Wisp downloads its speech models from Hugging Face. Nothing about you is sent.")
                ExplainerRow(symbol: "chart.bar.xaxis", text: "Wisp keeps no analytics. Timing measurements stay on this Mac and never include what you said or saw.")
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
        }
    }
}

/// Microphone or Screen Recording step with live status and the right action for the current state.
private struct PermissionStep: View {
    @ObservedObject var app: AppState
    var kind: PermissionKind
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let state = app.permissions.snapshot[kind]
        VStack(spacing: 24) {
            StepHeader(symbol: kind == .microphone ? "mic.circle" : "macwindow.on.rectangle",
                       title: kind == .microphone ? "Let Wisp hear you" : "Let Wisp see your screen",
                       subtitle: kind == .microphone
                       ? "Wisp listens only \(app.effectiveChord.whilePhrase). macOS shows an orange dot whenever the microphone is on."
                       : "Screenshots only \(app.effectiveChord.whilePhrase). Each one goes with your question to the AI that answers it, and Wisp doesn't keep it.")

            HStack(spacing: 14) {
                PermissionStatusRow(kind: kind, state: state)
                if state != .granted {
                    PermissionActionButtons(app: app, kind: kind, state: state)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))

            if kind == .screenRecording && state == .granted {
                AppDetailsRow(app: app, compact: true)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
            }
            if kind == .screenRecording {
                Text("Now and then macOS asks whether Wisp can keep seeing your screen. Allow it, and Wisp keeps working.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: state) { _, newValue in
            // Auto-advance shortly after the user grants access, so the change is visible first.
            if newValue == .granted && model.step == (kind == .microphone ? .microphone : .screen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    if model.step == (kind == .microphone ? .microphone : .screen) { model.advance() }
                }
            }
        }
    }
}

/// The right buttons for a permission in its current state (shared by onboarding, settings and recovery).
struct PermissionActionButtons: View {
    @ObservedObject var app: AppState
    var kind: PermissionKind
    var state: PermissionState

    var body: some View {
        if let card = RecoveryCard.make(kind: kind, state: state, chord: app.effectiveChord,
                                        wasPreviouslyGranted: app.permissions.wasEverGranted(kind)) {
            HStack(spacing: 10) {
                if let secondary = card.secondary, let label = card.secondaryLabel {
                    Button(label) { perform(secondary) }
                        .fixedSize()
                }
                Button(card.primaryLabel) { perform(card.primary) }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            }
        }
    }

    private func perform(_ action: RecoveryCard.Action) {
        switch action {
        case .requestAccess(let kind):
            Task { await app.permissions.request(kind) }
        case .openSettings(let kind):
            app.permissions.openSettings(kind)
        case .relaunch:
            Relauncher.relaunch(resumeOnboarding: !app.config.onboardingCompleted)
        }
    }
}

private struct ShortcutStep: View {
    @ObservedObject var app: AppState
    @ObservedObject var model: OnboardingModel

    /// Preset chords, plus the current one if it was recorded as a custom shortcut.
    static func options(including current: ModifierSet) -> [ModifierSet] {
        let presets: [ModifierSet] = [[.control, .option], [.option, .command], [.control, .command], [.control, .shift]]
        return presets.contains(current) ? presets : presets + [current]
    }

    var body: some View {
        let state = app.permissions.snapshot[.inputMonitoring]
        VStack(spacing: 20) {
            StepHeader(symbol: "keyboard",
                       title: "Choose your shortcut",
                       subtitle: "Hold these keys while you talk, and let go when you're done.")

            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Shortcut").gridColumnAlignment(.trailing)
                        Picker("Shortcut", selection: Binding(
                            get: { app.effectiveChord.modifiers },
                            set: { mods in app.setChordModifiers(mods) })) {
                            ForEach(Self.options(including: app.effectiveChord.modifiers), id: \.rawValue) { mods in
                                Text("\(mods.symbols)   \(mods.names)").tag(mods)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300, alignment: .leading)
                    }
                    GridRow {
                        Text("Your own")
                        ShortcutRecorderButton(app: app)
                    }
                    GridRow {
                        Text("Mode")
                        Picker("Mode", selection: Binding(
                            get: { app.effectiveChord.mode },
                            set: { mode in app.setChordMode(mode) })) {
                            Text("Hold to talk").tag(ChordMode.hold)
                            Text("Press to start, press again to stop").tag(ChordMode.toggle)
                        }
                        .labelsHidden()
                        .frame(width: 300, alignment: .leading)
                    }
                }
                .disabled(app.isLocked("chord"))

                if app.voiceOverRunning && app.effectiveChord.conflictsWithVoiceOver {
                    Label("VoiceOver is on and uses Control + Option. Pick a different shortcut so they don't collide.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Divider()
                ShortcutTestView(app: app)
                    .padding(.vertical, 4)
                Divider()
                PermissionStatusRow(kind: .inputMonitoring, state: state)
                Text("macOS lists this as Input Monitoring. Wisp uses it only to notice when your shortcut keys are held. It never records what you type.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state != .granted {
                    HStack { Spacer(); PermissionActionButtons(app: app, kind: .inputMonitoring, state: state) }
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
        }
    }
}

/// A real question, start to finish: everything is set up, so the shortcut now asks Wisp for real.
private struct TryItStep: View {
    @ObservedObject var app: AppState
    /// Answers counted when this page appeared; one more means it worked.
    @State private var baseline = 0

    private var answered: Bool { app.answeredQuestions > baseline }
    private var ready: Bool {
        let snap = app.permissions.snapshot
        return snap[.microphone] == .granted && snap[.inputMonitoring] == .granted && APIKeyStore.isConnected(app.config.vision)
    }

    var body: some View {
        let chord = app.effectiveChord
        VStack(spacing: 22) {
            StepHeader(symbol: "wand.and.stars",
                       title: "Try it out",
                       subtitle: "Ask Wisp something real, then make it yours below.",
                       compact: true)
            VStack(alignment: .leading, spacing: 16) {
                row(1) {
                    HStack(spacing: 10) {
                        Text(chord.mode == .hold ? "Hold" : "Press")
                        KeycapsView(modifiers: chord.modifiers)
                    }
                }
                row(2) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ask out loud, for example:")
                        Text("\u{201C}What can you do?\u{201D}  \u{201C}Where are the Wi-Fi settings?\u{201D}  \u{201C}What's 15% of 80?\u{201D}")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                row(3) {
                    Text(chord.mode == .hold
                         ? "Let go. Wisp answers out loud with captions, and points when it's about your screen."
                         : "Press again when you're done. Wisp answers out loud with captions, and points when it's about your screen.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if answered {
                    Label("That's it! Ask anything, any time, from any app.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else if ready {
                    Label("Waiting for your question…", systemImage: "ear")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Something from the earlier steps is missing (AI, microphone or shortcut), so Wisp can't answer yet. Go Back to finish it, or continue and fix it later in Settings.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
            .animation(.easeOut(duration: 0.2), value: answered)
            MakeItYoursCard(app: app)
            VStack(spacing: 4) {
                Text("To stop an answer, use the shortcut again or choose Stop from the Wisp menu.")
                Text("Wisp lives in the menu bar; settings are there too.")
            }
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .onAppear {
            baseline = app.answeredQuestions
            app.keys.isPracticing = false // real questions on this page
        }
    }

    private func row<Content: View>(_ n: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.callout.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(WispStyle.accent))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            content()
        }
    }
}

/// The few choices that shape how Wisp feels, next to the place you try it (all also in Settings).
private struct MakeItYoursCard: View {
    @ObservedObject var app: AppState

    var body: some View {
        let speech = app.config.speech
        let overlay = app.config.overlay
        VStack(alignment: .leading, spacing: 14) {
            Text("Make it yours").font(.headline)
            Text("Change anything and try again. You'll find all of this in Settings later.")
                .font(.callout).foregroundStyle(.secondary)

            group("Shortcut") {
                row("Keys") {
                    Picker("Keys", selection: Binding(
                        get: { app.effectiveChord.modifiers },
                        set: { mods in app.setChordModifiers(mods) })) {
                        ForEach(GeneralSettings.options(including: app.effectiveChord.modifiers), id: \.rawValue) { mods in
                            Text("\(mods.symbols)   \(mods.names)").tag(mods)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260, alignment: .leading)
                }
                row("Your own") { ShortcutRecorderButton(app: app) }
                row("Mode") {
                    Picker("Mode", selection: Binding(
                        get: { app.effectiveChord.mode },
                        set: { mode in app.setChordMode(mode) })) {
                        Text("Hold to talk").tag(ChordMode.hold)
                        Text("Press to start, press again to stop").tag(ChordMode.toggle)
                    }
                    .labelsHidden()
                    .frame(width: 260, alignment: .leading)
                }
            }
            .disabled(app.isLocked("chord"))

            group("Voice") {
                Toggle("Speak answers out loud", isOn: Binding(get: { speech.speakAnswers },
                                                               set: { v in app.update { $0.speech.speakAnswers = v } }))
                if speech.speakAnswers {
                    row("Voice") {
                        HStack {
                            Picker("Voice", selection: Binding(get: { speech.voiceID },
                                                               set: { v in app.update { $0.speech.voiceID = v } })) {
                                ForEach(VoiceCatalog.all) { voice in
                                    let ready = app.voiceAvailable?(voice.id) ?? true
                                    Text("\(voice.name), \(voice.detail)\(ready ? "" : " – not ready yet")").tag(voice.id)
                                }
                            }
                            .labelsHidden()
                            .disabled(app.isLocked("speech.voiceID"))
                            Button("Preview") { app.previewVoice?(speech.voiceID) }
                                .disabled(!(app.voiceAvailable?(speech.voiceID) ?? true))
                        }
                    }
                    row("Speed") {
                        CommitSlider(value: speech.rate, range: 0.7...1.4, step: 0.05, label: "Speaking speed") { v in
                            app.update { $0.speech.rate = v }
                        }
                    }
                } else {
                    Text("Answers appear as captions only.").font(.callout).foregroundStyle(.secondary)
                }
            }

            group("Companion cursor") {
                ThemeGallery(app: app, tileMinimum: 78)
                Picker("Companion", selection: Binding(get: { overlay.keepOnScreen },
                                                       set: { v in app.update { $0.overlay.keepOnScreen = v } })) {
                    Text("Only while I ask").tag(false)
                    Text("Always beside my pointer").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(app.isLocked("overlay.keepOnScreen"))
                row("Size") {
                    CommitSlider(value: overlay.cursorScale, range: OverlaySettings.scaleRange, label: "Companion size") { v in
                        app.update { $0.overlay.cursorScale = v }
                    }
                }
                .disabled(app.isLocked("overlay.cursorScale"))
                row("Opacity") {
                    CommitSlider(value: overlay.idleOpacity, range: OverlaySettings.idleOpacityRange, label: "Companion opacity") { v in
                        app.update { $0.overlay.idleOpacity = v }
                    }
                }
                .disabled(!overlay.keepOnScreen || app.isLocked("overlay.idleOpacity"))
                .help(overlay.keepOnScreen ? "How see-through the companion is while it waits beside your pointer." : "Applies when the companion stays beside your pointer.")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// A small "you can also…" hint on the last setup page.
private struct TipChip: View {
    var symbol: String
    var text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(WispStyle.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispStyle.groupedRow))
        .accessibilityElement(children: .combine)
    }
}

private struct DoneStep: View {
    @ObservedObject var app: AppState
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            let connected = APIKeyStore.isConnected(app.config.vision)
            let ready = app.permissions.snapshot.allGranted && connected
            StepHeader(symbol: "sparkles",
                       title: ready ? "You're all set" : "Almost ready",
                       subtitle: ready
                       ? "\(app.effectiveChord.mode == .hold ? "Hold" : "Press") \(app.effectiveChord.displayName), ask your question\(app.effectiveChord.mode == .hold ? ", then let go" : ", then press it again"). Wisp lives in the menu bar at the top of your screen."
                       : "Something below is still off. You can finish it any time from Wisp's icon in the menu bar at the top of your screen.")
            KeycapsView(modifiers: app.effectiveChord.modifiers)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionStatusRow(kind: kind, state: app.permissions.snapshot[kind])
                }
                let connected = APIKeyStore.isConnected(app.config.vision)
                HStack(spacing: 10) {
                    Image(systemName: connected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(connected ? .green : .orange)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text("AI connection")
                    Spacer()
                    if connected {
                        Text("On").foregroundStyle(.secondary).font(.callout)
                    } else {
                        Button("Add Key…") { model.go(to: .ai) }.controlSize(.small)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
            if ready {
                HStack(alignment: .top, spacing: 10) {
                    TipChip(symbol: "keyboard", text: "Double-tap Control to type a question")
                    TipChip(symbol: "text.bubble", text: "Select text and say “read this to me”")
                    TipChip(symbol: "list.number", text: "Ask “how do I…” and click each step")
                }
            }
            if LoginItem.isInstalled {
                Toggle("Open Wisp when you log in", isOn: $model.openAtLogin)
                    .toggleStyle(.checkbox)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Connects the vision AI: get a free NVIDIA key, paste it, and the connection is tested right away.
private struct AIStep: View {
    @ObservedObject var app: AppState
    @ObservedObject var model: OnboardingModel
    @State private var draft = ""
    @State private var state: AISettingsView.TestState = .idle
    @State private var saved = false

    private var provider: VisionProvider { VisionProvider(configID: app.config.vision.providerID) }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "sparkles.rectangle.stack",
                       title: "Connect Wisp's AI",
                       subtitle: provider == .nvidiaNIM
                       ? "Wisp uses a free NVIDIA account to understand your questions and your screen. It takes about a minute."
                       : "Use any service that speaks the OpenAI API: a cloud provider, or a model running on your own computer.")
            Picker("AI service", selection: Binding(
                get: { provider },
                set: { newValue in
                    guard newValue != provider else { return }
                    app.update {
                        $0.vision.providerID = newValue.rawValue
                        $0.vision.baseURL = newValue == .nvidiaNIM ? newValue.defaultBaseURL : ""
                        // A model name only means something to its own provider.
                        $0.vision.modelID = newValue == .nvidiaNIM ? VisionSettings.defaultModelID : ""
                    }
                    state = .idle
                    saved = APIKeyStore.isSaved(for: newValue)
                    model.aiKeySaved = APIKeyStore.isConnected(app.config.vision)
                })) {
                Text("NVIDIA (free)").tag(VisionProvider.nvidiaNIM)
                Text("Custom (OpenAI-compatible)").tag(VisionProvider.openAICompatible)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .disabled(app.isLocked("vision.providerID"))

            if provider == .openAICompatible {
                CustomProviderForm(app: app) { model.aiKeySaved = true }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
            } else {
                nvidiaCard
                Text("The key is encrypted and kept only on this Mac. You can change it any time in Settings > AI.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .onAppear { saved = APIKeyStore.isSaved(for: provider) }
    }

    private var nvidiaCard: some View {
            VStack(alignment: .leading, spacing: 16) {
                if saved {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Your key is saved on this Mac.")
                        Spacer()
                        Button("Change") { saved = false; state = .idle }
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        stepNumber(1)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Get a free key from NVIDIA")
                            Text("Sign in or create an account, then choose Generate API Key and copy it.")
                                .font(.callout).foregroundStyle(.secondary)
                            Link("Open NVIDIA's key page", destination: URL(string: "https://build.nvidia.com/settings/api-keys")!)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        stepNumber(2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Paste it here")
                            HStack {
                                SecureField("NVIDIA API key", text: $draft, prompt: Text("nvapi-…"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(save)
                                Button("Save", action: save)
                                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                switch state {
                case .idle: EmptyView()
                case .running: HStack { ProgressView().controlSize(.small); Text("Checking the connection…").foregroundStyle(.secondary) }
                case .ok: Label("Connected. Wisp is ready to answer.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .failed(let message):
                    if saved {
                        Label("Saved, but Wisp couldn't reach NVIDIA just now. It will work once NVIDIA can be reached; you can continue.",
                              systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                    } else {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                case .rejectedKey:
                    Label("That key didn't work. Make sure you copied all of it (it starts with nvapi-), then paste it again.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WispStyle.cornerRadius).fill(WispStyle.cardBackground))
    }

    private func stepNumber(_ n: Int) -> some View {
        Text("\(n)").font(.callout.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 22, height: 22).background(Circle().fill(WispStyle.accent))
    }

    private func save() {
        // People often copy the key with spaces or a line break around it.
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard APIKeyStore.save(key, for: provider) else { state = .failed("Couldn't save the key. Try again."); return }
        draft = ""
        saved = true
        model.aiKeySaved = true
        state = .running
        let config = app.config.vision
        let provider = self.provider
        Task {
            let result = await VisionConnectionTest.run(config: config, provider: provider)
            await MainActor.run {
                state = result
                if result == .rejectedKey {
                    // A wrong key is worse than none: forget it and ask again.
                    APIKeyStore.clear(for: provider)
                    saved = false
                    model.aiKeySaved = false
                }
            }
        }
    }
}
