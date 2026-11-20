import AppKit
import Combine
import WispCore

/// Observable, main-actor view of the app's configuration and services, shared by every window.
@MainActor
public final class AppState: ObservableObject {
    @Published public private(set) var config: AppConfig
    @Published public private(set) var voiceOverRunning: Bool
    public let configStore: ConfigStore
    public let permissions: PermissionService
    /// Live keyboard state for the shortcut test and recorder.
    public let keys = LiveKeyState()
    private var observers: [NSKeyValueObservation] = []
    private var cancellables: Set<AnyCancellable> = []

    public init(configStore: ConfigStore, permissions: PermissionService) {
        self.configStore = configStore
        self.permissions = permissions
        self.config = configStore.config
        WispStyle.theme = configStore.config.overlay.resolvedTheme
        self.voiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled
        observers.append(NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, change in
            let running = change.newValue ?? false
            Task { @MainActor in self?.voiceOverRunning = running }
        })
        // Re-publish permission changes so views observing AppState update too.
        permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    /// Applies a settings change through the layered store (managed keys stay as the admin set them).
    public func update(_ change: (inout AppConfig) -> Void) {
        do {
            config = try configStore.update(change)
            WispStyle.theme = config.overlay.resolvedTheme
        } catch {
            Log.app.error("saving settings failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Speaks a short sample in the given voice (Settings > Voice > Preview). Set by the app controller.
    public var previewVoice: ((String) -> Void)?
    /// Opens setup again from the welcome animation (Settings > General).
    public var replayWelcome: (() -> Void)?
    /// How many notes Wisp keeps (Settings > Privacy), and clearing them.
    @Published public var notesCount = 0
    public var clearNotes: (() -> Void)?
    /// Opens What's New (Settings > About).
    public var openWhatsNew: (() -> Void)?
    /// Opens the check-up window (Settings > About).
    public var openCheckup: (() -> Void)?
    /// Questions answered since launch; setup's practice page watches it.
    @Published public var answeredQuestions = 0
    /// Whether a voice can be heard right now (its file is installed and the voice model is loaded).
    public var voiceAvailable: ((String) -> Bool)?

    public func isLocked(_ keyPath: String) -> Bool { configStore.isLocked(keyPath) }

    /// The chord in effect. If the user never chose one and VoiceOver is running, swap in VoiceOver-safe
    /// keys (keeping the configured mode). An invalid chord (fewer than two keys) falls back to the default.
    public var effectiveChord: Chord {
        var chord = config.chord
        if !chord.isValid { chord.modifiers = Chord.controlOption.modifiers }
        if !config.chordChosenByUser && voiceOverRunning && chord.conflictsWithVoiceOver {
            chord.modifiers = Chord.recommendedDefault(voiceOverRunning: true).modifiers
        }
        return chord
    }

    /// Sets the chord keys, keeping the effective mode, and records that the user chose it.
    public func setChordModifiers(_ modifiers: ModifierSet) {
        let mode = effectiveChord.mode
        update { $0.chord = Chord(modifiers: modifiers, mode: mode); $0.chordChosenByUser = true }
    }

    /// Sets the chord mode, keeping the effective keys (so a VoiceOver-safe substitute is not lost).
    public func setChordMode(_ mode: ChordMode) {
        let modifiers = effectiveChord.modifiers
        update { $0.chord = Chord(modifiers: modifiers, mode: mode); $0.chordChosenByUser = true }
    }
}
