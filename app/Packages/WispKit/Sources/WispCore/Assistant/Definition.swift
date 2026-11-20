import Foundation

/// "Define ephemeral", "what's the definition of serendipity": answered from the dictionary built into macOS.
public enum Definition {
    /// The word asked about, or nil when the question isn't a dictionary lookup.
    public static func word(in question: String) -> String? {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!\"")))
        let patterns = [
            #"^(?:please |can you )?define (?:the word )?(?<w>[a-z][a-z'\-]*(?: [a-z][a-z'\-]*)?)$"#,
            #"^what(?:'s| is) the (?:definition|meaning) of (?:the word )?(?<w>[a-z][a-z'\-]*(?: [a-z][a-z'\-]*)?)$"#,
            #"^what does the word (?<w>[a-z][a-z'\-]*) mean$"#,
            #"^(?:look up|look) (?<w>[a-z][a-z'\-]*) in the dictionary$"#,
            #"^(?:the )?meaning of (?:the word )?(?<w>[a-z][a-z'\-]*)$"#,
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p),
                  let m = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
                  let r = Range(m.range(withName: "w"), in: q) else { continue }
            let w = String(q[r])
            if ["this", "that", "it", "these", "those"].contains(w) { return nil } // about the screen
            return w
        }
        return nil
    }

    /// The first sense, said simply: "Ephemeral, adjective: lasting for a very short time."
    public static func spoken(word: String, entry: String) -> String {
        let parts = entry.components(separatedBy: "|")
        var body = (parts.count >= 3 ? parts[2...].joined(separator: "|") : entry).trimmingCharacters(in: .whitespaces)
        let kinds = ["noun", "verb", "adjective", "adverb", "pronoun", "preposition", "conjunction", "exclamation", "abbreviation"]
        var kind: String?
        if let first = body.split(separator: " ").first, kinds.contains(String(first)) {
            kind = String(first)
            body = String(body.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
        }
        // Drop a leading sense number and labels like "[with object]" or "(chiefly British)".
        body = body.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        let end = body.firstIndex(where: { $0 == ":" || $0 == "•" || $0 == "." }) ?? body.endIndex
        let sense = body[..<end].trimmingCharacters(in: .whitespaces)
        let name = word.prefix(1).uppercased() + word.dropFirst()
        guard !sense.isEmpty else { return "\(name): \(entry.prefix(200))" }
        return kind.map { "\(name), \($0): \(sense)." } ?? "\(name): \(sense)."
    }
}
