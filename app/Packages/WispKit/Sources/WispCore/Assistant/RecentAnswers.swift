import Foundation

/// The last few questions and answers, newest first. Kept in memory only (gone when Wisp quits) so the user can
/// hear or copy an answer again.
public struct RecentAnswers: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var question: String
        public var sentences: [String]
        public var date: Date
        public var answer: String { sentences.joined(separator: " ") }
    }

    public static let capacity = 10
    public private(set) var entries: [Entry] = []

    public init() {}

    public var last: Entry? { entries.first }

    public mutating func add(question: String, sentences: [String], date: Date = Date()) {
        let spoken = sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !spoken.isEmpty else { return }
        entries.insert(Entry(question: question.trimmingCharacters(in: .whitespacesAndNewlines), sentences: spoken, date: date), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    public mutating func clear() { entries.removeAll() }

    /// A menu title for a question: first letter capitalised, at most `limit` characters (cut at a word).
    public static func title(for question: String, limit: Int = 48) -> String {
        var text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "(no words)" }
        text = text.prefix(1).uppercased() + text.dropFirst()
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:")) + "…"
    }
}
