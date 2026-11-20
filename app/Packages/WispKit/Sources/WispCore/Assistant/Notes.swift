import Foundation

/// Things the user asked Wisp to remember ("remember that my parking spot is B12"). Kept on this Mac only, never
/// sent to the AI; read back on request.
public struct Notes: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable {
        public var text: String
        public var date: Date
    }

    public static let capacity = 100
    public private(set) var items: [Note] = []

    public init() {}

    public enum Command: Equatable, Sendable { case add(String), list, clear, forget(String) }

    public static func parse(_ question: String) -> Command? {
        let q = question.replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!")))
        let lower = q.lowercased()
        if lower.range(of: #"^(?:wisp,? )?(?:clear|delete|forget|erase) (?:all )?(?:my |the |your )?notes$|^forget everything i (?:told|asked) you to remember$"#,
                       options: .regularExpression) != nil { return .clear }
        if let r = lower.range(of: #"^(?:wisp,? )?(?:forget|delete|remove) (?:the |my )?note (?:about|on|that says) "#, options: .regularExpression) {
            let topic = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return topic.isEmpty ? nil : .forget(topic)
        }
        if lower.range(of: #"^(?:wisp,? )?(?:what are my notes|read (?:me )?my notes|show (?:me )?my notes|what did i (?:ask|tell) you to remember|what do you remember|my notes)$"#,
                       options: .regularExpression) != nil { return .list }
        for lead in ["remember that ", "please remember that ", "note that ", "make a note that ", "make a note: ",
                     "make a note ", "take a note: ", "take a note that ", "take a note ", "wisp, remember that ", "wisp remember that "]
        where lower.hasPrefix(lead) {
            var text = String(q.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
            guard text.split(separator: " ").count >= 2 else { return nil }
            // Stored as said back to them: "my" → "your".
            text = text.replacingOccurrences(of: #"\bmy\b"#, with: "your", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\bI am\b"#, with: "you are", options: .regularExpression)
                .replacingOccurrences(of: #"\bI'm\b"#, with: "you're", options: .regularExpression)
                .replacingOccurrences(of: #"\bI\b"#, with: "you", options: .regularExpression)
            return .add(text)
        }
        return nil
    }

    public mutating func add(_ text: String, date: Date = Date()) {
        items.append(Note(text: text, date: date))
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }

    public mutating func clear() { items.removeAll() }

    /// Removes the newest note mentioning every word of `topic`; returns it, or nil if none matches.
    public mutating func forget(_ topic: String) -> Note? {
        let words = topic.lowercased().replacingOccurrences(of: #"\bmy\b"#, with: "your", options: .regularExpression)
            .split(separator: " ").map(String.init)
        guard let index = items.lastIndex(where: { n in words.allSatisfy { n.text.lowercased().contains($0) } }) else { return nil }
        return items.remove(at: index)
    }

    /// Read back, newest first: "You asked me to remember: your parking spot is B12. And: …".
    public var spoken: String {
        guard !items.isEmpty else { return "You haven't asked me to remember anything yet. Say “remember that…” and I will." }
        let texts = items.reversed().prefix(5).map(\.text)
        var out = "You asked me to remember: " + texts.joined(separator: ". And: ") + "."
        if items.count > 5 { out += " There are \(items.count - 5) more in the card." }
        return out
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL) -> Notes {
        guard let data = try? Data(contentsOf: url), let notes = try? JSONDecoder().decode(Notes.self, from: data) else { return Notes() }
        return notes
    }
}
