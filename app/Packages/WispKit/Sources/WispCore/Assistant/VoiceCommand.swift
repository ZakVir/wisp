import Foundation

/// Spoken requests that change how Wisp talks ("talk faster", "be quiet"): handled on the Mac, no AI needed.
public enum VoiceCommand: Equatable, Sendable {
    case faster, slower, normalSpeed, mute, unmute
    /// "Stop", "be quiet", "never mind": holding the shortcut already stopped the answer; nothing more to do or say.
    case hush

    public static func parse(_ question: String) -> VoiceCommand? {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lead = #"^(wisp,? |hey wisp,? |can you |could you |please )*"#
        let tail = #"( please)?( wisp)?$"#
        func m(_ body: String) -> Bool { q.range(of: lead + body + tail, options: .regularExpression) != nil }
        if m(#"(talk|speak|go|read) (a (little |bit )?)?(faster|quicker|more quickly)"#) || m("speed up") { return .faster }
        if m(#"(talk|speak|go|read) (a (little |bit )?)?(slower|more slowly)"#) || m("slow down") { return .slower }
        if m(#"(talk|speak) (at )?(normal|regular) speed"#) || m("normal speed") { return .normalSpeed }
        if m(#"(stop talking out loud|stop speaking out loud|mute (your voice|yourself)|captions only|just show (me )?(the )?captions|don't talk out loud|no voice)"#) { return .mute }
        if m(#"(stop|stop it|stop that|stop talking|be quiet|quiet|shh+|hush|shut up|enough|that's enough|never ?mind|cancel|forget it|nothing)"#) { return .hush }
        if m(#"(talk to me again|speak (out loud )?again|turn (your|the) voice (back )?on|unmute( yourself)?|use your voice again)"#) { return .unmute }
        return nil
    }

    /// The speech rate after the command (0.5…2.0, steps of 0.15).
    public func rate(from current: Double) -> Double {
        switch self {
        case .faster: return (min(2.0, current + 0.15) * 100).rounded() / 100
        case .slower: return (max(0.5, current - 0.15) * 100).rounded() / 100
        case .normalSpeed: return 1.0
        case .mute, .unmute, .hush: return current
        }
    }

    public var confirmation: String {
        switch self {
        case .faster: return "Okay, I'll talk a little faster."
        case .slower: return "Okay, I'll talk a little slower."
        case .normalSpeed: return "Back to my normal speed."
        case .mute: return "Okay, captions only from now on. Say “turn your voice back on” any time."
        case .unmute: return "Okay, I'll talk out loud again."
        case .hush: return ""
        }
    }
}
