import Foundation

/// "Draw a star", "draw a smiley face": shapes the companion draws itself, stroke by stroke, around the pointer.
/// Coordinates are in a unit box (-1...1, y up) and scaled onto the screen by the app.
public enum Drawing {
    public enum Shape: String, CaseIterable, Sendable {
        case circle, square, rectangle, triangle, star, heart, smiley, check, arrow, spiral, house, line
    }

    private static let names: [(String, Shape)] = [
        ("smiley face", .smiley), ("smiley", .smiley), ("happy face", .smiley), ("smile", .smiley), ("face", .smiley),
        ("check mark", .check), ("checkmark", .check), ("tick", .check), ("circle", .circle), ("square", .square),
        ("rectangle", .rectangle), ("box", .square), ("triangle", .triangle), ("star", .star), ("heart", .heart),
        ("arrow", .arrow), ("spiral", .spiral), ("house", .house), ("line", .line),
    ]

    /// Questions that ask Wisp to draw ("draw a cat", "can you draw a star", "sketch a house").
    public static func isDrawRequest(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return q.range(of: #"^(?:wisp,? |hey wisp,? )?(?:can you |could you |please |now )*(?:draw|sketch|doodle)\b"#, options: .regularExpression) != nil
    }

    /// A shape Wisp draws by itself ("draw a big star"), or nil (anything else goes to the AI, which can draw too).
    public static func shape(in question: String) -> Shape? {
        guard isDrawRequest(question) else { return nil }
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let rest = q.replacingOccurrences(of: #"^(?:wisp,? |hey wisp,? )?(?:can you |could you |please |now )*(?:draw|sketch|doodle)\s+(?:me\s+)?(?:an?\s+|the\s+|some\s+)?(?:big\s+|small\s+|little\s+|large\s+|nice\s+)?"#,
                                          with: "", options: .regularExpression)
        let suffix = #"(?:\s+(?:on|on my|on the)\s+(?:the\s+)?screen|\s+here|\s+for me|\s+please)*$"#
        for (name, shape) in names where rest.range(of: "^" + name + suffix, options: .regularExpression) != nil { return shape }
        return nil
    }

    /// The strokes of `shape` in a unit box (-1...1, y up), each drawn in one go.
    public static func strokes(_ shape: Shape) -> [[Vec2]] {
        func ellipse(cx: Double = 0, cy: Double = 0, rx: Double, ry: Double, from a0: Double = 0, to a1: Double = 2 * .pi, n: Int = 48) -> [Vec2] {
            (0...n).map { i in let a = a0 + (a1 - a0) * Double(i) / Double(n); return Vec2(cx + rx * cos(a), cy + ry * sin(a)) }
        }
        switch shape {
        case .circle: return [ellipse(rx: 1, ry: 1, from: .pi / 2, to: .pi / 2 + 2 * .pi)]
        case .square: return [[Vec2(-1, 1), Vec2(1, 1), Vec2(1, -1), Vec2(-1, -1), Vec2(-1, 1)]]
        case .rectangle: return [[Vec2(-1, 0.6), Vec2(1, 0.6), Vec2(1, -0.6), Vec2(-1, -0.6), Vec2(-1, 0.6)]]
        case .triangle: return [[Vec2(0, 1), Vec2(0.95, -0.75), Vec2(-0.95, -0.75), Vec2(0, 1)]]
        case .star:
            let pts = (0...10).map { i -> Vec2 in
                let a = .pi / 2 + Double(i) * .pi / 5
                let r = i % 2 == 0 ? 1.0 : 0.42
                return Vec2(r * cos(a), r * sin(a))
            }
            return [pts]
        case .heart:
            return [(0...64).map { i -> Vec2 in
                let t = Double(i) / 64 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                return Vec2(x / 17, (y + 2) / 17)
            }]
        case .smiley:
            return [ellipse(rx: 1, ry: 1, from: .pi / 2, to: .pi / 2 + 2 * .pi),
                    ellipse(cx: -0.35, cy: 0.3, rx: 0.1, ry: 0.14, n: 16),
                    ellipse(cx: 0.35, cy: 0.3, rx: 0.1, ry: 0.14, n: 16),
                    ellipse(cx: 0, cy: -0.05, rx: 0.55, ry: 0.5, from: .pi * 1.15, to: .pi * 1.85, n: 24)]
        case .check: return [[Vec2(-0.9, 0), Vec2(-0.3, -0.6), Vec2(0.9, 0.8)]]
        case .arrow: return [[Vec2(-1, 0), Vec2(1, 0)], [Vec2(0.5, 0.45), Vec2(1, 0), Vec2(0.5, -0.45)]]
        case .spiral:
            return [(0...96).map { i -> Vec2 in
                let t = Double(i) / 96
                let a = t * 6 * .pi, r = 0.08 + 0.92 * t
                return Vec2(r * cos(a), r * sin(a))
            }]
        case .house:
            return [[Vec2(-0.75, 0.1), Vec2(-0.75, -0.9), Vec2(0.75, -0.9), Vec2(0.75, 0.1)],
                    [Vec2(-0.95, 0.05), Vec2(0, 0.9), Vec2(0.95, 0.05)],
                    [Vec2(-0.2, -0.9), Vec2(-0.2, -0.35), Vec2(0.2, -0.35), Vec2(0.2, -0.9)]]
        case .line: return [[Vec2(-1, 0), Vec2(1, 0)]]
        }
    }

    /// "Draw a cat": a picture on its own (sketched by the AI in a small box, drawn around the pointer), as opposed to
    /// marking something on the screen ("draw a box around the title"), which the screen-aware answer handles.
    public static func isFreeSketch(_ question: String) -> Bool {
        guard isDrawRequest(question), shape(in: question) == nil else { return false }
        let q = question.lowercased()
        let onScreen = [" around ", " under ", " underline", " over the ", " next to ", " pointing ", " arrow to ", " arrow at ",
                        " circle the ", " on the button", " the title", " this button", " that button", " this text", " the text"]
        return !onScreen.contains { q.contains($0) } && !q.hasSuffix(" around it") && !q.hasSuffix(" around that")
    }

    /// What to draw: "draw me a cat on the screen" → "a cat".
    public static func subject(of question: String) -> String {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var rest = q.replacingOccurrences(of: #"^(?:wisp,? |hey wisp,? )?(?:can you |could you |please |now )*(?:draw|sketch|doodle)\s+(?:me\s+)?"#,
                                          with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"(?:\s+(?:on|on my|on the)\s+(?:the\s+)?screen|\s+here|\s+for me|\s+please)+$"#,
                                         with: "", options: .regularExpression)
        return rest.isEmpty ? "something nice" : rest
    }

    /// The instructions for sketching (no screenshot): strokes as points in a 100 × 100 box, one stroke per line.
    public static let sketchPrompt = """
    You make simple line drawings, like a quick pen sketch. Reply with only the strokes, one per line, each a list \
    of points "x,y x,y x,y ..." in a 100 by 100 box (x from the left, y from the top). Use 4 to 14 strokes and 3 to \
    30 points each, so the drawing is recognisable: the outline first, then the details. No words, no numbering, \
    nothing else.
    """

    /// One stroke line ("30,50 25,40 20,30") as points in the 100 × 100 box; nil if it isn't one.
    public static func parseStroke(_ line: String) -> [Vec2]? {
        var points: [Vec2] = []
        for token in line.split(whereSeparator: { $0 == " " || $0 == ";" }) {
            let parts = token.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0].trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: ".-")))),
                  let y = Double(parts[1].trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: ".-")))),
                  (-5...105).contains(x), (-5...105).contains(y) else { continue }
            points.append(Vec2(x, y))
        }
        return points.count >= 2 ? Array(points.prefix(60)) : nil
    }

    /// Pen speed for drawings: slower than pointing so the drawing can be watched (0.6–2.6 s per stroke).
    public static func duration(forLength length: Double) -> Double { min(2.6, max(0.6, length / 380)) }
}
