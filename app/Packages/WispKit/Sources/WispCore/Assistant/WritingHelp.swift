import Foundation

/// "Make this more polite", "fix the grammar", "translate this into French" with text selected: Wisp writes the
/// new version (no screenshot needed), shows it and puts it on the clipboard. It never types it in for them.
public enum WritingHelp {
    public static func isRequest(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let this = #"(this|it|that|the (selected )?text|my (text|email|message|paragraph)|the (email|message|paragraph|sentence|page|article|document|post))( (page|article|email|document|post))?"#
        let patterns = [
            #"^(can you |could you |please |wisp,? )*(rewrite|rephrase|reword|redo|polish|tidy up|clean up|improve|edit) "# + this,
            #"^(can you |could you |please |wisp,? )*(fix|correct|check) (the )?(grammar|spelling|typos|punctuation|mistakes)"#,
            #"^(can you |could you |please |wisp,? )*proofread "# + this,
            #"^(can you |could you |please |wisp,? )*(summari[sz]e|shorten|condense|simplify|expand on) "# + this,
            #"^(can you |could you |please |wisp,? )*translate "# + this + #" (to|into) [a-z]+"#,
            #"^(can you |could you |please |wisp,? )*make "# + this + #" (sound )?(more |less |a (bit|little) (more |less )?)?(shorter|longer|formal|informal|friendlier|friendly|clearer|simpler|polite|professional|casual|concise|warmer|nicer|kinder|confident|persuasive|positive)"#,
            #"^(can you |could you |please |wisp,? )*turn "# + this + #" into (bullet points|a (bulleted )?list|an email|a tweet|a summary|a paragraph)"#,
            #"^(can you |could you |please |wisp,? )*write a (reply|response|answer) to "# + this,
            #"^(can you |could you |please |wisp,? )*(give me |what are )(the )?(key|main) (points|takeaways)( of "# + this + ")?",
            #"^(can you |could you |please |wisp,? )*(give me (a |the )|what's the |what is the )?(summary|tl;?dr|gist) of "# + this,
        ]
        return patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }

    public static let systemPrompt = """
    You help people with their writing. They selected some text on their Mac and asked for a change. Reply with \
    only the new text, ready to paste in place of theirs: no introduction, no quotation marks around it, no notes \
    afterwards. Keep their language unless they ask for a translation, keep their meaning and any names, numbers \
    and links, and keep line breaks and lists where they help. When they ask for a reply to a message, write the \
    reply as them. A summary, gist or list of key points is much shorter than the original: only the few things \
    that matter most, in two to four short sentences or up to five bullet points, easy to take in by ear.
    """

    /// Summaries and key points are worth hearing; other results (a rewrite, a translation) are for pasting.
    public static func isSummary(_ request: String) -> Bool {
        request.lowercased().range(of: #"summar|tl;?dr|gist|key points|main points|takeaways|shorten|condense"#, options: .regularExpression) != nil
    }

    public static func userText(request: String, selection: String) -> String {
        let length = isSummary(request) ? "\n(It will be read aloud: keep it to about 50 words.)" : ""
        return "What they asked: \"\(request)\"\(length)\n\nThe text they selected:\n\(selection)"
    }

    /// The model's reply cleaned for pasting: surrounding quotes or a "Here's…:" lead-in removed.
    public static func cleaned(_ reply: String) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = t.range(of: #"^(here('s| is) [^\n:]{0,60}:|sure[!,.][^\n:]{0,60}:)\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[range.upperBound...])
        }
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”")]
        for (open, close) in quotes where t.count > 2 && t.first == open && t.last == close && !t.dropFirst().dropLast().contains(close) {
            t = String(t.dropFirst().dropLast())
        }
        // Markdown's two-space line breaks and other trailing spaces don't belong in pasted text.
        t = t.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }.joined(separator: "\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
