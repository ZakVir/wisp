import Foundation

/// Timers and reminders said out loud ("set a timer for 5 minutes", "remind me in 20 minutes to call Sam",
/// "remind me at 3 pm to send the report"). Pure parsing and bookkeeping; the app schedules and announces them.
public enum TimerCommand: Equatable, Sendable {
    case set(seconds: TimeInterval, label: String?)
    case at(hour: Int, minute: Int, label: String?)
    case cancel
    case status
    /// "Snooze" / "snooze for 5 minutes": the last reminder or timer again, later (default 10 minutes).
    case snooze(seconds: TimeInterval)
    /// "Add 5 minutes to my timer".
    case extend(seconds: TimeInterval)

    public static func parse(_ question: String) -> TimerCommand? {
        // Case is kept for the label ("call Sam"); every pattern ignores case.
        let q = question.replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let lower = q.lowercased()
        if lower.range(of: #"^(please )?(cancel|stop|delete|clear) (my |the |all (my |the )?)?(timers?|reminders?)$"#, options: .regularExpression) != nil { return .cancel }
        if lower.range(of: #"^(how much time is left|how long is left|how long until my (timer|reminder)|what's left on my timer|time left)( on my timer)?$"#, options: .regularExpression) != nil { return .status }
        let lead = #"^(wisp,? |hey wisp,? |can you |could you |please )*"#
        if lower.range(of: #"^(please )?snooze( it)?$|^remind me again( later)?$"#, options: .regularExpression) != nil { return .snooze(seconds: 600) }
        if let m = q.firstMatch(#"^(?:please )?snooze(?: it)? (?:for )?(?<n>[\w.\- ]+?) (?<u>seconds?|minutes?|mins?|hours?)$"#),
           let n = number(m["n"] ?? ""), let unit = m["u"] { return .snooze(seconds: n * multiplier(unit)) }
        if let m = q.firstMatch(#"^(?:please )?add (?<n>[\w.\- ]+?) (?<u>seconds?|minutes?|mins?|hours?) (?:to|on) (?:my|the) timer$"#),
           let n = number(m["n"] ?? ""), let unit = m["u"] { return .extend(seconds: n * multiplier(unit)) }
        // "set a timer for 5 minutes", "timer 90 seconds", "start a 10 minute timer"
        if let m = q.firstMatch(lead + #"(set|start) (a |an )?timer (for )?(?<n>[\w.\- ]+?) (?<u>seconds?|secs?|minutes?|mins?|hours?|hrs?)( called (?<label>.+))?$"#)
            ?? q.firstMatch(lead + #"(set|start) (a |an )?(?<n>[\w.\-]+)[ -](?<u>second|minute|hour)s? timer( (for|called) (?<label>.+))?$"#)
            ?? q.firstMatch(lead + #"timer (for )?(?<n>[\w.\- ]+?) (?<u>seconds?|minutes?|hours?)$"#),
           let n = number(m["n"] ?? ""), let unit = m["u"] {
            return .set(seconds: n * multiplier(unit), label: m["label"].map(clean))
        }
        // "remind me in 20 minutes to call Sam", "remind me to call Sam in 20 minutes"
        if let m = q.firstMatch(lead + #"remind me in (?<n>[\w.\- ]+?) (?<u>seconds?|minutes?|mins?|hours?|hrs?)( to | that | about )(?<label>.+)$"#)
            ?? q.firstMatch(lead + #"remind me (to |that |about )(?<label>.+?) in (?<n>[\w.\- ]+?) (?<u>seconds?|minutes?|mins?|hours?|hrs?)$"#),
           let n = number(m["n"] ?? ""), let unit = m["u"] {
            return .set(seconds: n * multiplier(unit), label: m["label"].map(clean))
        }
        // "remind me at 3 pm to send the report", "remind me to stretch at 4:30"
        if let m = q.firstMatch(lead + #"remind me at (?<t>\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)?)( to | that | about )(?<label>.+)$"#)
            ?? q.firstMatch(lead + #"remind me (to |that |about )(?<label>.+?) at (?<t>\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)?)$"#),
           let (h, mi) = clock(m["t"] ?? "") {
            return .at(hour: h, minute: mi, label: m["label"].map(clean))
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\bmy\b"#, with: "your", options: [.regularExpression, .caseInsensitive])
    }

    static func multiplier(_ unit: String) -> TimeInterval {
        let unit = unit.lowercased()
        return unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1
    }

    /// "5", "2.5", "five", "twenty five", "a", "an", "half an" (only the common ones people say).
    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let d = Double(t) { return d }
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                       "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
                                       "thirty": 30, "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
                                       "half an": 0.5, "half a": 0.5, "a couple of": 2, "a couple": 2, "couple of": 2]
        if let w = words[t] { return w }
        let parts = t.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        if parts.count == 2, let tens = words[parts[0]], let ones = words[parts[1]], tens >= 20, ones < 10 { return tens + ones }
        return nil
    }

    /// "3 pm" → (15, 0); "4:30" → (4, 30) (the app picks the next 4:30); "12 am" → (0, 0).
    static func clock(_ s: String) -> (Int, Int)? {
        let t = s.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
        guard let m = t.firstMatch(#"^(?<h>\d{1,2})(:(?<m>\d{2}))?(?<p>am|pm)?$"#), var h = Int(m["h"] ?? "") else { return nil }
        let minute = Int(m["m"] ?? "0") ?? 0
        guard h <= 23, minute < 60 else { return nil }
        if let p = m["p"] {
            guard h >= 1, h <= 12 else { return nil }
            h = h % 12 + (p == "pm" ? 12 : 0)
        }
        return (h, minute)
    }

    /// When an `.at` time falls next: today if still ahead (or, without am/pm, the next of h and h+12), else tomorrow.
    public static func nextDate(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        var candidates: [Date] = []
        for h in hour < 12 ? [hour, hour + 12] : [hour] {
            if let d = calendar.nextDate(after: now, matching: DateComponents(hour: h, minute: minute), matchingPolicy: .nextTime) { candidates.append(d) }
        }
        return candidates.min() ?? now.addingTimeInterval(3600)
    }

    /// "5 minutes", "1 hour 30 minutes", "45 seconds".
    public static func spoken(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        if sec > 0 && h == 0 { parts.append("\(sec) second\(sec == 1 ? "" : "s")") }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }
}

extension String {
    /// Named capture groups of the first match of `pattern`, or nil.
    func firstMatch(_ pattern: String) -> [String: String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        var out: [String: String] = [:]
        for name in ["n", "u", "label", "t", "h", "m", "p"] {
            let r = match.range(withName: name)
            if r.location != NSNotFound, let range = Range(r, in: self) { out[name] = String(self[range]) }
        }
        return out
    }
}
