import Foundation

/// Speech-to-text quality metrics (word error rate and entity accuracy) for the D1 evaluation.
public enum STTMetrics {
    /// Lowercased words with punctuation removed; "Save As." → ["save", "as"]. Numbers kept.
    public static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let cleaned = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(cleaned).split(separator: " ").map { $0.replacingOccurrences(of: "'", with: "") }.filter { !$0.isEmpty }
    }

    /// Word-level edit distance (substitutions + insertions + deletions).
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Word error rate of `hypothesis` against `reference` (0 = perfect).
    public static func wer(reference: String, hypothesis: String) -> Double {
        let r = words(reference)
        guard !r.isEmpty else { return words(hypothesis).isEmpty ? 0 : 1 }
        return Double(editDistance(r, words(hypothesis))) / Double(r.count)
    }

    /// True when every word of `entity` appears consecutively in the hypothesis.
    /// Spacing inside a term doesn't count as an error ("quick time" = "QuickTime", "Da Vinci" = "DaVinci"):
    /// the words of the hypothesis are compared with spaces removed.
    public static func containsEntity(_ entity: String, in hypothesis: String) -> Bool {
        let e = words(entity).joined(), h = words(hypothesis)
        guard !e.isEmpty else { return false }
        for start in h.indices {
            var joined = ""
            for end in start..<h.count {
                joined += h[end]
                if joined == e { return true }
                if joined.count >= e.count { break }
            }
        }
        return false
    }

    /// One corpus line: "utterance | entity; entity".
    public struct Item: Equatable, Sendable {
        public var text: String
        public var entities: [String]
    }

    public static func parseCorpus(_ text: String) -> [Item] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let entities = parts.count > 1 ? parts[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
            return Item(text: parts[0], entities: entities)
        }
    }
}
