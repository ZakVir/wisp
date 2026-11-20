import Foundation

/// A content-free summary of how Wisp has been used, from the local timing log (Settings > About).
public struct UsageStats: Equatable, Sendable {
    public var answered = 0
    public var answeredThisWeek = 0
    /// Answered on the Mac without the AI (math, timers, read aloud, dictionary…).
    public var answeredLocally = 0
    /// Median time from letting go of the shortcut to the first spoken word, for AI answers.
    public var medianStartMs: Int?

    static let failures: Set<String> = ["stt_not_ready", "stt_failed", "empty_question", "no_screenshot", "capture_failed",
                                        "encode_failed", "no_model", "bad_base_url", "superseded", "offline"]
    static let local: Set<String> = ["math", "definition", "timer", "read_aloud", "read_page", "copy_text", "repeat",
                                     "voice_command", "shortcuts", "magnify"]

    public init() {}

    public static func from(_ timings: [TurnTiming], now: Date = Date()) -> UsageStats {
        var stats = UsageStats()
        let weekAgo = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        var starts: [Int] = []
        for t in timings where !failures.contains(t.outcome) && !t.outcome.hasPrefix("vision_") {
            stats.answered += 1
            if let d = t.date, d >= weekAgo { stats.answeredThisWeek += 1 }
            if local.contains(t.outcome) { stats.answeredLocally += 1; continue }
            if let ms = TurnTiming.ms(t.keyUp, t.firstAudio), ms > 0, ms < 60_000 { starts.append(ms) }
        }
        stats.medianStartMs = Stats.percentile(starts, 50)
        return stats
    }
}
