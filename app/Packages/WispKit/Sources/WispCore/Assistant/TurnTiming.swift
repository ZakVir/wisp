import Foundation

/// Per-stage timestamps of one turn (`ProcessInfo.systemUptime`, seconds). Content-free by construction.
public struct TurnTiming: Codable, Sendable, Equatable {
    public var keyDown: Double
    /// When the turn happened (seconds since 1970), for weekly counts. Nil in older records.
    public var date: Double? = Date().timeIntervalSince1970
    public var captureStart: Double?
    public var captureReady: Double?
    public var keyUp: Double?
    public var sttFinal: Double?
    public var requestSent: Double?
    public var firstToken: Double?
    public var firstSentence: Double?
    public var firstAudio: Double?
    public var done: Double?
    public var model: String?
    public var ttsEngine: String?
    public var outcome: String = "ok"
    public var attempts: Int = 0
    /// This hold interrupted a spoken answer: ms from key-down until the speaker went quiet
    /// (stop call + device output latency).
    public var bargeInStop: Int?

    public init(keyDown: Double) { self.keyDown = keyDown }

    /// Milliseconds between two stages, if both happened.
    public static func ms(_ a: Double?, _ b: Double?) -> Int? {
        guard let a, let b else { return nil }
        return Int(((b - a) * 1000).rounded())
    }

    /// Derived intervals used in reports (all ms).
    public var summary: [String: Int] {
        var out: [String: Int] = [:]
        out["capture_after_keydown"] = Self.ms(keyDown, captureReady)
        out["capture_duration"] = Self.ms(captureStart, captureReady)
        if let bargeInStop { out["barge_in_stop"] = bargeInStop }
        out["stt_final_after_keyup"] = Self.ms(keyUp, sttFinal)
        out["request_after_keyup"] = Self.ms(keyUp, requestSent)
        out["first_token_after_request"] = Self.ms(requestSent, firstToken)
        out["first_audio_after_keyup"] = Self.ms(keyUp, firstAudio)
        out["first_sentence_after_keyup"] = Self.ms(keyUp, firstSentence)
        return out
    }
}

/// Percentile over a sample (nearest-rank).
public enum Stats {
    public static func percentile(_ values: [Int], _ p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
