import Foundation

/// Kokoro voices Wisp offers (hexgrad Kokoro-82M v1.0's best-graded English voices). Heart ships with the main
/// voice model; the others come with the "Kokoro extra voices" download.
public struct VoiceOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
}

public enum VoiceCatalog {
    public static let defaultID = "af_heart"
    public static let all: [VoiceOption] = [
        VoiceOption(id: "af_heart", name: "Heart", detail: "American, warm (default)"),
        VoiceOption(id: "af_bella", name: "Bella", detail: "American, bright"),
        VoiceOption(id: "af_nicole", name: "Nicole", detail: "American, soft and close"),
        VoiceOption(id: "af_sarah", name: "Sarah", detail: "American, clear"),
        VoiceOption(id: "af_nova", name: "Nova", detail: "American, even"),
        VoiceOption(id: "bf_emma", name: "Emma", detail: "British"),
        VoiceOption(id: "bf_isabella", name: "Isabella", detail: "British"),
        VoiceOption(id: "am_michael", name: "Michael", detail: "American, male"),
        VoiceOption(id: "am_fenrir", name: "Fenrir", detail: "American, male, deeper"),
        VoiceOption(id: "am_puck", name: "Puck", detail: "American, male, lively"),
        VoiceOption(id: "bm_george", name: "George", detail: "British, male"),
        VoiceOption(id: "bm_fable", name: "Fable", detail: "British, male"),
    ]
    public static func option(_ id: String) -> VoiceOption { all.first { $0.id == id } ?? all[0] }
}
