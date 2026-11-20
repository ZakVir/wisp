import Foundation

/// Small things answered on the Mac: spelling a word, flipping a coin, rolling a die, picking a number.
public enum LittleHelpers {
    public static func answer(_ question: String, random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> String? {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        func match(_ p: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: p), let m = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) else { return nil }
            return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: q).map { String(q[$0]) } ?? "" }
        }
        if let m = match(#"^(?:how do you spell|how do i spell|spell|how is) ([a-z][a-z'\-]{1,30})(?: spelled| spelt)?$"#) {
            let word = m[1]
            let letters = word.uppercased().map { String($0) }.joined(separator: ", ")
            return "\(word.prefix(1).uppercased() + word.dropFirst()) is spelled \(letters)."
        }
        if match(#"^(?:can you |please )?(?:flip|toss) a coin$|^heads or tails$"#) != nil {
            return random(0...1) == 0 ? "Heads." : "Tails."
        }
        if match(#"^(?:can you |please )?roll (?:a|the|one) (?:die|dice)$"#) != nil {
            return "You rolled a \(random(1...6))."
        }
        if let m = match(#"^(?:can you |please )?(?:pick|choose|give me) a (?:random )?number (?:between|from) (\d{1,9}) (?:and|to) (\d{1,9})$"#),
           let a = Int(m[1]), let b = Int(m[2]), a != b {
            return "\(random(min(a, b)...max(a, b)))."
        }
        return nil
    }
}
