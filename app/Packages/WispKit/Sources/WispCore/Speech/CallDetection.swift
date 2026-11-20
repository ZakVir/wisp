import Foundation

/// Which microphone users count as "someone else is recording" (a call), for answering quietly during calls.
public enum CallDetection {
    /// macOS's own background listeners keep the microphone open all the time ("Hey Siri", dictation, Sound
    /// Recognition, Voice Control); they're never a call.
    static let systemListeners = [
        "com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.siri", "com.apple.assistantd",
        "com.apple.SpeechRecognitionCore", "com.apple.speech", "com.apple.dictation", "com.apple.DictationIM",
        "com.apple.accessibility", "com.apple.VoiceControl", "com.apple.voicebankingd", "com.apple.hearingd",
        "com.apple.audio.SandboxHelper",
    ]

    /// A process (by the bundle ID Core Audio reports) whose microphone use counts as a call.
    public static func countsAsCall(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return true }  // unknown: be careful, count it
        return !systemListeners.contains { id.hasPrefix($0.lowercased()) }
    }
}
