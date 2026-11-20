import Foundation

/// Every question and answer of this session, and, only if the user turns on "Keep history on this Mac", earlier
/// ones too (text only: never screenshots or audio). Newest first, capped.
public struct History: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var date: Date
        public var question: String
        public var answer: String
        /// The app that was in front.
        public var app: String?
        public var typed: Bool

        public init(id: UUID = UUID(), date: Date = Date(), question: String, answer: String, app: String?, typed: Bool) {
            self.id = id; self.date = date; self.question = question; self.answer = answer; self.app = app; self.typed = typed
        }
    }

    public static let capacity = 300
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = Array(entries.prefix(Self.capacity)) }

    public mutating func add(_ entry: Entry) {
        guard !entry.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    public mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    public mutating func clear() { entries.removeAll() }

    /// Entries whose question, answer or app contain every word of `query` (case-insensitive).
    public func search(_ query: String) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in
            let hay = (e.question + " " + e.answer + " " + (e.app ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// "What did you tell me about cropping earlier?" → "cropping" (the topic to look up in History).
    public static func recallTopic(_ question: String) -> String? {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        let pattern = #"^what did (?:you|wisp) (?:say|tell me|answer) (?:about|on|for) (?<t>.+?)(?: earlier| before| last time| today)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let r = Range(m.range(withName: "t"), in: q) else { return nil }
        let topic = String(q[r]).trimmingCharacters(in: .whitespaces)
        return topic.isEmpty ? nil : topic
    }

    /// The newest entry about `topic` (words matched loosely: "cropping" finds "crop").
    public func recall(_ topic: String) -> Entry? {
        let words = topic.split(separator: " ").map { w -> String in
            var s = String(w)
            for suffix in ["ping", "ing", "ed", "es", "s"] where s.count > suffix.count + 2 && s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)); break }
            return s
        }.filter { !["the", "a", "an", "my", "this", "that"].contains($0) }
        guard !words.isEmpty else { return nil }
        return entries.first { e in
            let hay = (e.question + " " + e.answer).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: Saving (only when the user keeps history)

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL) -> History {
        guard let data = try? Data(contentsOf: url), let history = try? JSONDecoder().decode(History.self, from: data) else { return History() }
        return history
    }
}
