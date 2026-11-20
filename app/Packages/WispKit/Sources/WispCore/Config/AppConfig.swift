import Foundation

/// Every user-tunable setting, with built-in defaults. Persisted as layered JSON (see `ConfigStore`).
public struct AppConfig: Codable, Equatable, Sendable {
    public var chord: Chord = .controlOption
    /// Whether the user (or onboarding) has explicitly chosen a chord. When false the app may pick a
    /// VoiceOver-safe default automatically.
    public var chordChosenByUser: Bool = false
    /// Double-tap Control to type a question instead of saying it.
    public var typeToAsk: Bool = true
    /// The key tapped twice to type a question: "control", "option", "command" or "shift".
    public var typeKey: String = "control"
    public var typeKeyModifier: ModifierSet {
        switch typeKey { case "option": return .option; case "command": return .command; case "shift": return .shift; default: return .control }
    }
    /// After a how-to answer that points somewhere, clicking there shows the next step.
    public var guideSteps: Bool = true
    /// "Search online for …", "open YouTube": Wisp opens it in the default browser (a new tab).
    public var allowWebActions: Bool = true
    /// The full answer to a typed question also appears in a card (with Copy).
    public var answerCard: Bool = true
    /// Spoken questions' answers also appear in the card.
    public var answerCardAlways: Bool = false
    public var vision: VisionSettings = .init()
    public var models: ModelSourceSettings = .init()
    public var speech: SpeechSettings = .init()
    public var overlay: OverlaySettings = .init()
    public var privacy: PrivacySettings = .init()
    public var onboardingCompleted: Bool = false

    public init() {}
}

public struct VisionSettings: Codable, Equatable, Sendable {
    /// Provider adapter identifier, e.g. "nvidia-nim", "openai-compatible", "anthropic".
    public var providerID: String = "nvidia-nim"
    public var baseURL: String = "https://integrate.api.nvidia.com/v1"
    public var modelID: String = VisionSettings.defaultModelID
    /// Fallback models tried, in order, when the primary fails or produces degenerate output (the primary itself
    /// is skipped).
    public var fallbackModelIDs: [String] = VisionSettings.defaultFallbackModelIDs
    /// Seconds before a request is considered stuck.
    public var timeoutSeconds: Double = 20
    /// Long edge, in pixels, of the screenshot sent to the model.
    public var imageLongEdge: Int = 1456
    /// With several displays, also send the other displays (so Wisp can point at them). Up to 3 in total.
    public var captureAllDisplays: Bool = true
    /// With the Accessibility permission, read the front app's controls and menu commands for each question.
    public var readAppControls: Bool = true
    /// NVIDIA: questions go to Nemotron 3.5 Super VL first (Nano as backup), drawings to Step 5 Preview (QuestionRouter).
    public var smartRouting: Bool = true
    /// The user's own words about themselves and how they like answers, sent with every question.
    public var instructions: String = ""
    public static let maxInstructions = 500
    /// "short", "normal" or "detailed".
    public var answerLength: String = "normal"
    /// How a model Wisp doesn't know (a custom provider's) gives screen positions.
    public var customCoordinateSpace: ModelCoordinateSpace = .imagePixels
    public init() {}

    /// The model to ask: the catalog's entry, or, for a model it doesn't know, the position format chosen in settings.
    public var modelInfo: VisionModelInfo {
        var info = VisionModelCatalog.info(for: modelID)
        if !VisionModelCatalog.nim.contains(where: { $0.id == info.id }) { info.coordinateSpace = customCoordinateSpace }
        return info
    }

    /// Display name of the configured model ("Nemotron 3 Nano Omni"), for privacy copy and settings.
    public var modelDisplayName: String { VisionModelCatalog.info(for: modelID).displayName }

    /// Plain-language description of which screens are sent, for privacy copy.
    public var screensSentDescription: String {
        captureAllDisplays
            ? "a screenshot of the display you're using, plus your other displays if you have more than one (up to three)"
            : "a screenshot of the display you're using"
    }

    /// Most accurate and fastest free NIM model in the M8 bake-off (docs/FINDINGS.md §6): 98% synthetic / 75% real-app
    /// pointing hit rate, ~1.2 s to point. Nemotron 3.5 Super VL is more accurate on real apps (94% vs 86%) but about 2× slower.
    public static let defaultModelID = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
    public static let defaultFallbackModelIDs = ["nvidia/nemotron-3.5-super-vl-120b-a12b", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"]

    /// Human-readable name of the company that receives screenshots, for privacy copy.
    public var providerDisplayName: String {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        switch true {
        case host.hasSuffix("nvidia.com"): return "NVIDIA"
        case host.hasSuffix("anthropic.com"): return "Anthropic"
        case host.hasSuffix("openai.com"): return "OpenAI"
        case host.hasSuffix("googleapis.com"): return "Google"
        case host == "localhost" || host == "127.0.0.1": return "a local server on this Mac"
        default: return host.isEmpty ? "the configured provider" : host
        }
    }
}

public struct ModelSourceSettings: Codable, Equatable, Sendable {
    /// Remote signed manifest checked for model updates. When nil, the manifest bundled in the app is
    /// used (it is signed and verified the same way). Point this at your CDN to ship model updates
    /// without an app update.
    public var manifestURL: String? = nil
    /// Alternate base URLs tried in order when a file's primary URL fails. A file whose primary URL is
    /// `<anything>/<path>` is fetched from `<mirror>/<model id>/<version>/<file name>`.
    public var mirrorBaseURLs: [String] = []
    /// A folder containing pre-provisioned model files (offline installs). Checked before any download.
    public var offlineFolder: String? = nil
    /// Minimum hours between automatic manifest checks.
    public var checkIntervalHours: Double = 24
    public init() {}
}

public struct SpeechSettings: Codable, Equatable, Sendable {
    public var voiceID: String = "af_heart"
    /// 0.5 ... 2.0, multiplies the voice's natural speed.
    public var rate: Double = 1.0
    public var volume: Double = 1.0
    public var showCaptions: Bool = true
    /// "small", "medium" or "large".
    public var captionSize: String = "medium"
    /// Briefly show the words Wisp heard before it answers.
    public var showHeard: Bool = true
    /// "pointer" (beside the mouse pointer) or "bottom" (centred near the bottom, like subtitles).
    public var captionPosition: String = "pointer"
    public var captionScale: Double {
        switch captionSize { case "small": return 0.87; case "large": return 1.3; default: return 1 }
    }
    /// Off: answers appear as captions only (still paced like speech), nothing is heard.
    public var speakAnswers: Bool = true
    public var earcons: Bool = true
    /// When another app is using the microphone (a call), answer with captions and the answer card instead of out loud.
    public var quietDuringCalls: Bool = true
    /// Microphone chosen in Settings (Core Audio device UID); nil = the system default input.
    public var inputDeviceUID: String? = nil

    /// Volume the voice actually plays at (0 when answers aren't spoken).
    public var effectiveVolume: Double { speakAnswers ? volume : 0 }
    /// Captions are always shown when answers aren't spoken; otherwise they're the user's choice.
    public var effectiveShowCaptions: Bool { showCaptions || !speakAnswers }
    public init() {}
}

public struct OverlaySettings: Codable, Equatable, Sendable {
    public var cursorThemeID: String = "aurora"
    /// Companion size multiplier (0.6 ... 2.0; 1.0 ≈ 1.3× the macOS pointer).
    public var cursorScale: Double = 1.0
    /// Keep the companion beside the pointer all the time. Off: it lives in the menu bar and flies out only
    /// while you ask a question, then flies home.
    public var keepOnScreen: Bool = false
    /// Opacity while the companion is idle beside the pointer (keep-on-screen mode), 0.2 ... 1.0.
    public var idleOpacity: Double = 0.85
    /// Outline drawn around the companion (white like the macOS pointer by default).
    public var outline: CompanionOutline = .white
    public var reduceMotion: ReduceMotionPreference = .system
    /// The user's own skin (used when `cursorThemeID` is "custom").
    public var customSkin: CustomSkin? = nil
    public init() {}

    public static let scaleRange: ClosedRange<Double> = 0.6...2.0
    public static let idleOpacityRange: ClosedRange<Double> = 0.2...1.0

    /// Values clamped to their allowed ranges (protects against hand-edited or managed files).
    public var sanitized: OverlaySettings {
        var copy = self
        copy.cursorScale = min(max(cursorScale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        copy.idleOpacity = min(max(idleOpacity, Self.idleOpacityRange.lowerBound), Self.idleOpacityRange.upperBound)
        return copy
    }
}

public enum CompanionOutline: String, Codable, Sendable, CaseIterable {
    case white, black, none
}

public enum ReduceMotionPreference: String, Codable, Sendable, CaseIterable {
    case system, on, off
}

public struct PrivacySettings: Codable, Equatable, Sendable {
    /// The user has read and accepted that each question's screenshot(s) and text go to the vision provider.
    public var cloudDisclosureAccepted: Bool = false
    /// Keep per-stage timings in a local file (never content).
    public var localTimingLog: Bool = true
    /// Apps Wisp never sees (bundle identifiers): left out of screenshots, and their buttons and text aren't read.
    public var privateApps: [String] = []
    /// Keep questions and answers (text only) between launches, for History.
    public var keepHistory: Bool = false
    public init() {}
}
