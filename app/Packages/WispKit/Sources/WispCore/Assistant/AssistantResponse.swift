import Foundation

/// One thing the assistant wants to do, parsed from the model's tagged-line output.
/// Coordinates are in the model's coordinate space for the sent image (see `ModelCoordinateSpace`).
public enum AssistantEvent: Equatable, Sendable {
    /// What the question is about, declared on the reply's first line. Only `.screen` replies show anything.
    public enum Topic: String, Sendable { case screen, you, other }

    /// The model's reading of the question (first line of the reply; never spoken).
    case topic(Topic)
    /// A sentence (or a few) to speak and caption.
    case say(String)
    /// Fly to a point and highlight it.
    case point(x: Double, y: Double, label: String)
    /// Draw around a rectangle (x, y = top-left).
    case circle(x: Double, y: Double, width: Double, height: Double, label: String)
    /// Draw a line under something.
    case underline(x1: Double, y1: Double, x2: Double, y2: Double, label: String)
    /// Draw an arrow from (x1, y1) to (x2, y2).
    case arrow(x1: Double, y1: Double, x2: Double, y2: Double, label: String)
    /// Draw a freehand path through points.
    case path(points: [Vec2], label: String)
    /// A visual on another display: `screen` is the 1-based number of the screenshot it refers to (2, 3, …).
    indirect case onScreen(Int, AssistantEvent)
    /// In a step-by-step walkthrough: whether more steps follow the one just given (never spoken).
    case steps(more: Bool)

    public var isVisual: Bool {
        switch self {
        case .say, .topic, .steps: return false
        default: return true
        }
    }

    /// The label the model gave a visual ("Export", "Save button"), nil for speech and topic lines.
    public var label: String? {
        switch self {
        case .say, .topic, .steps: return nil
        case .point(_, _, let label), .circle(_, _, _, _, let label), .underline(_, _, _, _, let label),
             .arrow(_, _, _, _, let label), .path(_, let label): return label
        case .onScreen(_, let inner): return inner.label
        }
    }

    /// The screenshot index (0-based) this event refers to, and the event itself.
    public var screenAndEvent: (Int, AssistantEvent) {
        if case .onScreen(let n, let inner) = self { return (max(0, n - 1), inner) }
        return (0, self)
    }
}

/// Incremental parser for the tagged-line protocol:
///
///     SAY: Click Export in the top right.
///     POINT: 1290, 790 | Export
///     CIRCLE: 1180, 760, 220, 60 | Export button
///     UNDERLINE: 300, 140, 420, 140 | Crop
///     ARROW: 900, 500, 1290, 790 | Export
///     PATH: 10,10 50,40 90,10 | squiggle
///
/// Feed streamed text with `consume`; complete lines are returned as soon as their newline arrives, so speech
/// can start before the model finishes. Untagged lines are treated as speech (models sometimes forget the tag),
/// markdown decoration is stripped, and malformed visual lines are dropped (never crash, never guess).
public struct ResponseParser: Sendable {
    private var buffer = ""
    private var inThink = false

    public init() {}

    public mutating func consume(_ chunk: String) -> [AssistantEvent] {
        buffer += chunk
        stripReasoning()
        var events: [AssistantEvent] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            events += Self.parseSegments(line)
        }
        return events
    }

    /// Splits a line where a model put several tags on one line ("… corner. POINT: 1430, 790 | Export").
    static func parseSegments(_ line: String) -> [AssistantEvent] {
        let pattern = #"(?<=\s)(SAY|POINT|CIRCLE|UNDERLINE|ARROW|PATH)\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return parseLine(line).map { [$0] } ?? [] }
        let ns = line as NSString
        let starts = regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        guard !starts.isEmpty else { return parseLine(line).map { [$0] } ?? [] }
        var segments: [String] = []
        var prev = 0
        for start in starts {
            segments.append(ns.substring(with: NSRange(location: prev, length: start - prev)))
            prev = start
        }
        segments.append(ns.substring(from: prev))
        return segments.compactMap { parseLine($0) }
    }

    /// Call when the stream ends to parse the last line (which has no trailing newline).
    public mutating func finish() -> [AssistantEvent] {
        stripReasoning()
        let rest = inThink ? "" : buffer
        buffer = ""
        return Self.parseSegments(rest)
    }

    /// Reasoning that leaks into the answer is never spoken: "<think>…</think>" blocks are dropped, and so is
    /// anything before a stray closing tag (a model that "thinks" with its tags cut off).
    private mutating func stripReasoning() {
        while true {
            if inThink {
                guard let close = buffer.range(of: "</think>") else { buffer = ""; return }
                buffer.removeSubrange(buffer.startIndex..<close.upperBound)
                inThink = false
            } else if let open = buffer.range(of: "<think>") {
                if let close = buffer.range(of: "</think>", range: open.upperBound..<buffer.endIndex) {
                    buffer.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    buffer.removeSubrange(open.lowerBound...)
                    inThink = true
                    return
                }
            } else if let close = buffer.range(of: "</think>") {
                buffer.removeSubrange(buffer.startIndex..<close.upperBound)
            } else {
                return
            }
        }
    }

    static let tags = ["TOPIC", "SAY", "POINT", "CIRCLE", "UNDERLINE", "ARROW", "PATH", "STEPS"]

    public static func parseLine(_ raw: String) -> AssistantEvent? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown bullets/emphasis/code fences that some models add.
        if line.hasPrefix("```") { return nil }
        while let first = line.first, "-*•>".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        guard !line.isEmpty else { return nil }
        // A line with no words (",", "---", stray symbols) is a glitch, not speech.
        let hasWords = line.contains { $0.isLetter || $0.isNumber }

        guard let colon = line.firstIndex(of: ":") else { return hasWords ? .say(line) : nil }
        let tag = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
        guard tags.contains(tag) else { return hasWords ? .say(line) : nil }
        let body = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        if tag == "TOPIC" {
            // Never spoken. Unknown values count as "other" so an unclear reading never moves the cursor.
            let word = body.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
            if word == "wisp" { return .topic(.you) }
            return .topic(AssistantEvent.Topic(rawValue: word) ?? (word.hasPrefix("screen") ? .screen : .other))
        }
        if tag == "STEPS" {
            // "more" / "done"; anything that isn't clearly "more" ends the walkthrough (never leaves someone waiting).
            let word = body.lowercased()
            let more = ["more", "next", "continue", "yes"].contains { word.hasPrefix($0) }
            return .steps(more: more)
        }
        if tag == "SAY" {
            let text = body.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
            return text.isEmpty ? nil : .say(text)
        }

        let (geometry, rawLabel) = splitLabel(body)
        let (label, screen) = Self.extractScreen(rawLabel)
        let numbers = Self.numbers(in: geometry)
        guard let event = visual(tag: tag, numbers: numbers, label: label) else { return nil }
        return screen.map { $0 > 1 ? .onScreen($0, event) : event } ?? event
    }

    /// "Export | screen 2" or "terminal:screen2" → ("Export", 2).
    static func extractScreen(_ label: String) -> (String, Int?) {
        let pattern = #"[|:,]?\s*screen\s*(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return (label, nil) }
        let ns = label as NSString
        guard let m = regex.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)),
              let n = Int(ns.substring(with: m.range(at: 1))) else { return (label, nil) }
        let rest = ns.substring(to: m.range.location).trimmingCharacters(in: CharacterSet(charactersIn: " |:,\"“”"))
        return (rest, n)
    }

    static func visual(tag: String, numbers: [Double], label: String) -> AssistantEvent? {
        switch tag {
        case "POINT":
            guard numbers.count >= 2 else { return nil }
            return .point(x: numbers[0], y: numbers[1], label: label)
        case "CIRCLE":
            if numbers.count >= 4 {
                return .circle(x: numbers[0], y: numbers[1], width: abs(numbers[2]), height: abs(numbers[3]), label: label)
            }
            return nil
        case "UNDERLINE":
            guard numbers.count >= 4 else { return nil }
            return .underline(x1: numbers[0], y1: numbers[1], x2: numbers[2], y2: numbers[3], label: label)
        case "ARROW":
            guard numbers.count >= 4 else { return nil }
            return .arrow(x1: numbers[0], y1: numbers[1], x2: numbers[2], y2: numbers[3], label: label)
        case "PATH":
            guard numbers.count >= 4 else { return nil }
            var points: [Vec2] = []
            var i = 0
            while i + 1 < numbers.count { points.append(Vec2(numbers[i], numbers[i + 1])); i += 2 }
            return .path(points: Array(points.prefix(64)), label: label)
        default:
            return nil
        }
    }

    /// "1290, 790 | Export" → ("1290, 790", "Export"). Also accepts a quoted label without a bar.
    static func splitLabel(_ body: String) -> (String, String) {
        if let bar = body.firstIndex(of: "|") {
            let label = body[body.index(after: bar)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'"))
            return (String(body[..<bar]), label)
        }
        if let quote = body.firstIndex(where: { $0 == "\"" || $0 == "“" }) {
            let label = body[quote...].trimmingCharacters(in: CharacterSet(charactersIn: " \"“”"))
            return (String(body[..<quote]), label)
        }
        return (body, "")
    }

    /// All finite numbers in `s` (handles "(812, 404)", "x=812 y=404", decimals, negatives).
    static func numbers(in s: String) -> [Double] {
        var out: [Double] = []
        var current = ""
        func flush() {
            if let v = Double(current), v.isFinite { out.append(v) }
            current = ""
        }
        for ch in s {
            if ch.isNumber || (ch == "." && !current.contains(".")) || (ch == "-" && current.isEmpty) {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}

/// Splits spoken text into sentences for sentence-by-sentence speech and captions.
public enum SentenceSplitter {
    public static func split(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        return out.isEmpty && !text.trimmingCharacters(in: .whitespaces).isEmpty ? [text] : out
    }
}

/// Detects broken model output, e.g. Kimi K3's occasional runs of "!!!!!!!!".
public struct DegenerateOutputDetector: Sendable {
    private var text = ""
    public init() {}

    /// Returns true once the accumulated output looks degenerate.
    public mutating func feed(_ chunk: String) -> Bool {
        text += chunk
        return Self.isDegenerate(text)
    }

    public static func isDegenerate(_ text: String) -> Bool {
        // 1. A run of 8+ identical non-alphanumeric characters ("!!!!!!!!", "????????", "........" excluding "...").
        var runChar: Character? = nil
        var run = 0
        for ch in text {
            if ch == runChar { run += 1 } else { runChar = ch; run = 1 }
            if run >= 8, !ch.isLetter, !ch.isNumber, !ch.isWhitespace, ch != "-", ch != "=" { return true }
        }
        // 2. Mostly punctuation once there is enough text to judge.
        let visible = text.filter { !$0.isWhitespace }
        if visible.count >= 40 {
            let punct = visible.filter { !$0.isLetter && !$0.isNumber && !",.|:'\"()-".contains($0) }.count
            if Double(punct) / Double(visible.count) > 0.5 { return true }
        }
        // 3. The same short chunk repeated many times at the end ("the the the the …").
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count >= 12 {
            let tail = words.suffix(12)
            if Set(tail).count <= 2 { return true }
        }
        return false
    }
}

/// What kind of question the user asked, where it changes how Wisp answers.
public enum QuestionIntent {
    /// Questions about Wisp itself ("what can you do?", "who are you?"). Their answers never point: smaller models
    /// tend to point at whatever assistant or logo is on screen (seen with Nemotron, 2026-10-01).
    public static func isAboutAssistant(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
        let patterns = [
            #"\bwhat (else )?can you do\b"#, #"\bwhat do you do( exactly)?\??$"#, #"\bwho are you\b"#,
            #"\bwhat are you( exactly| for| called)?\??$"#, #"\bwhat('s| is) your name\b"#, #"\bhow do you work\b"#,
            #"\bwhat are you able to\b"#, #"\bwhat can i ask you\b"#, #"\bhow (do|can) i use you\b"#,
            #"\bare you (an? )?(ai|robot|bot|human)\b"#, #"\byour (job|purpose|name)\b"#,
            #"\bare you (claude|siri|chatgpt|gemini|alexa|copilot)\b"#, #"\bwho (made|built|created) you\b"#,
            #"\bcan you (remember|see everything|always see)\b"#, #"\bcan you (click|type) (things|stuff|for me)\b"#,
            #"\bcan you see (my|the) screen\b"#, #"\bcan you do (the )?(math|maths|sums|stuff|things)\b"#,
            #"\bwhat can you help( me)?( with)?\??$"#, #"\bdo you remember\b"#,
        ]
        return patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }

    /// Greetings, thanks and filler ("hey", "thanks!", "never mind", "test test"): answered in a few words, never
    /// with pointing.
    public static func isSmallTalk(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(hey|hi|hello|hello there|hey there|yo|thanks|thank you|thank you so much|thanks a lot|cool|ok|okay|great|nice|never ?mind|good (morning|afternoon|evening|night)|test|test test|testing|can you hear me|are you there|um+|uh+|hm+|oops|my bad|sorry|sorry,? wrong (button|key|thing)|wrong (button|key))( wisp)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// True when a spoken sentence says the thing isn't there ("I don't see an undo button"). A pointing line after
    /// such a sentence would contradict it (small models still add one), so it is dropped.
    public static func deniesPresence(_ sentence: String) -> Bool {
        let s = sentence.lowercased().replacingOccurrences(of: "’", with: "'")
        let pattern = #"\b(i (don't|do not|can't|cannot) (see|find)|there('s| is) no (?!need|problem|rush|worries|harm)|there (isn't|aren't)|(isn't|aren't|is not|are not) (shown|visible|here|on (this|the|your) (screen|page))|no [a-z ]{1,24} (here|on (this|the) (screen|page)))"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// True when a spoken sentence asks the user something back ("To do what, exactly?"): Wisp isn't sure what they
    /// mean yet, so there is nothing to show.
    public static func asksBack(_ sentence: String) -> Bool {
        sentence.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"”'"))).hasSuffix("?")
    }

    /// True when the sentence itself names the thing a visual points at ("Click the Subscribe button" + a point
    /// labelled "Subscribe"). The model sometimes labels a question "other" and then answers it from the screen
    /// anyway; a point its own words name is trustworthy, so it is still shown. Labels that aren't a name on the
    /// screen ("not visible", "none") never count.
    public static func sentenceNames(label: String, in sentence: String) -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s*\((button|icon|menu|tab|link|field|option|checkbox)\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(button|icon|menu item|menu|tab|link|field|option|checkbox|toggle)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard name.count >= 2 || (name.count == 1 && sentence.contains("\"\(name)\"")) else { return false }
        let banned = ["not visible", "none", "n/a", "nothing", "screen", "the screen", "window", "page", "not shown", "unknown"]
        if banned.contains(name.lowercased()) { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
        return sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// An answer that isn't about the screen sometimes opens with a hedge before the real answer ("I can't help with
    /// cooking, but here's how…", "I don't see the weather on your screen, but London is mild…"). The hedge is
    /// dropped when a real answer of a few words follows it; otherwise the sentence is left alone.
    public static func withoutHedge(_ sentence: String) -> String {
        let pattern = #"^\s*(i (can't|cannot|can not) help with [^,.;]{0,40}|i (don't|do not|can't|cannot) see [^,.;]{0,70}|i'm not (sure|able to [^,.;]{0,30})[^,.;]{0,20}),?\s+but\s+"#
        let s = sentence.replacingOccurrences(of: "’", with: "'")
        guard let range = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return sentence }
        var rest = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard rest.split(separator: " ").count >= 4 else { return sentence }
        rest = rest.prefix(1).uppercased() + rest.dropFirst()
        return rest
    }

    /// "Read this to me", "read it out loud", "read the selected text": the user wants their selected text read
    /// aloud word for word (done on the Mac, no AI needed), not a summary.
    public static func isReadAloud(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(can you |could you |please |wisp,? )*read (this|that|it|the (selected|highlighted) (text|part|bit)|what i('ve| have)? (selected|highlighted)|the selection|my selection)( (out )?(loud|aloud))?( (to|for) me)?( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// "Copy the text on my screen", "copy all the text in this image": the visible text to the clipboard.
    public static func isCopyScreenText(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(can you |could you |please |wisp,? )*(copy|grab|get) (all )?(the |of the )?(text|words|writing)( that's| that is)? (on|from|in) (my |the |this |that )?(screen|image|picture|photo|video|window|page|slide|screenshot)( for me)?( please)?$|^(can you |could you |please )*copy (what's|what is|everything) on (my |the )?screen( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// "What are the keyboard shortcuts here?", "show me the shortcuts": the front app's shortcut list.
    public static func isShortcutList(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(can you |could you |please |wisp,? )*((show|list|tell) me (all )?(the |its |the app's )?(keyboard )?shortcuts|what are (all )?(the )?(keyboard )?shortcuts|(show|list) (all )?(the )?(keyboard )?shortcuts|(keyboard )?shortcuts)( (here|for this( app)?|in this( app)?|for (this|the) app|in (this|the) app))?( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// The question is about what they copied ("what does what I copied mean?", "translate my clipboard"): only
    /// then does the clipboard's text go with it.
    public static func mentionsClipboard(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
        let pattern = #"\b(clipboard|what i('ve| have)? (just )?copied|the (text|thing|stuff|link|code) i (just )?copied|what's copied|(i|i've) (just )?copied)\b"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// "Magnify this", "give me a closer look", "show me this bigger": an enlarged view of the area around the
    /// pointer (not a how-to question like "how do I make it bigger").
    public static func isMagnify(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(can you |could you |please |wisp,? )*(magnify (this|that|it|here)|zoom in on (this|that|it|here) for me|(give me|take|show me) a closer look|closer look|(show|let) me (see )?(this|that|it) (bigger|larger|closer|up close)|magnifier|enlarge (this|that|it) for me)( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// "What can you do?", "what can you help with?": Wisp's own abilities, answered from a fixed list (the model
    /// can't know which features this version has).
    public static func asksCapabilities(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return q.range(of: #"^(wisp,? |so,? |okay,? )?(what (else )?can you do|what can you help (me )?with|what are you able to do|how can you help( me)?|what do you do)( for me)?$"#,
                       options: .regularExpression) != nil
    }

    public static let capabilitiesSpoken = "I answer questions about whatever's on your screen and point to the right spot, step by step if you like. I can also read text aloud, help with writing, summarize a page, do math and conversions, set timers, and keep notes. Double-tap Control to see more."

    public static let capabilitiesCard = """
    • Ask about your screen: “how do I export this as a PDF?” (Wisp points; click along for the next step)
    • “What does this mean?” with text selected, or “what does this do?” pointing at a button
    • Read aloud: “read this to me”, “read this page to me”, “read what I copied”
    • Writing: “make this more polite”, “fix the grammar”, “translate this into Spanish”, “summarize this page”
    • Instant: “what's 15% of 80?”, “5 miles in km”, “what time is it in Tokyo?”, “define ephemeral”
    • Timers and notes: “remind me in 20 minutes to call Sam”, “remember that my parking spot is B12”
    • More: “copy the text on my screen”, “magnify this”, “what are the shortcuts here?”, “try again”
    """

    /// "Keep reading", "read more", "go on": continue a long page where reading stopped.
    public static func isKeepReading(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return q.range(of: #"^(please |wisp,? )*(keep reading|read more|continue reading|continue|go on|keep going|read the rest)( please)?$"#,
                       options: .regularExpression) != nil
    }

    /// Splits long text for reading aloud: the first part (cut at a sentence end near `limit`) and the rest.
    public static func readingChunk(_ text: String, limit: Int = 8000) -> (String, String?) {
        guard text.count > limit else { return (text, nil) }
        let head = text.prefix(limit)
        let cut = head.lastIndex(where: { ".!?\n".contains($0) }).map { head.index(after: $0) } ?? head.endIndex
        let first = String(text[..<cut]), rest = String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (first, rest.isEmpty ? nil : rest)
    }

    /// "Read what I copied", "read my clipboard out loud".
    public static func isReadClipboard(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(can you |could you |please |wisp,? )*read (me )?(what i('ve| have)? (just )?copied|my clipboard|the clipboard|what's on my clipboard)( (out )?(loud|aloud))?( (to|for) me)?( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// "Read this page to me", "read the article out loud": the front window's text read aloud.
    public static func isReadPage(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(can you |could you |please |wisp,? )*read (me )?(this|the|my) (page|article|screen|window|document|email|message|story|post)( (out )?(loud|aloud))?( (to|for) me)?( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// "Try again", "that's not right", "second opinion": ask the last question again, with the other model.
    public static func isRetry(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(no,? |nope,? |hmm,? |wisp,? )*(try again|try that again|ask again|that's (not right|wrong|incorrect)|that is (not right|wrong)|that's not it|wrong answer|you're wrong|(get|give me) a second opinion|second opinion|are you sure|check again|look again)( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// "Say that again", "repeat that", "what did you say?": the last answer again, word for word.
    public static func isRepeat(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^(sorry,? |wisp,? |can you |could you |please )*(say (that|it) again|repeat (that|it|yourself|the answer|your answer|what you (just )?said)|what did you (just )?say|come again|pardon( me)?|one more time|say again)( please)?$"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether pointing/drawing should be shown for answers to this question.
    public static func allowsPointing(_ question: String) -> Bool {
        !isAboutAssistant(question) && !isSmallTalk(question)
    }
}
