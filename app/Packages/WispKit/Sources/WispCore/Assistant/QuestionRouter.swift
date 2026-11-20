import Foundation

/// Which free NVIDIA model answers first. Every question goes to Nemotron 3.5 Super VL first (94-96% right on the
/// real-app test, about 2 s), with Nemotron Nano (about 1 s) as its fallback. Quick how-to questions used to go to
/// Nano first, but Nano answers them from habit ("New Session in the File menu") even with the right button on the
/// screen and named in the app details (4/12 on the Claude test, Super VL 12/12; FINDINGS §12). Drawings go to
/// Step 5 Preview, the only free model whose sketches look like the thing asked for.
public enum QuestionRouter {
    public static let fastModelID = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
    public static let strongModelID = "nvidia/nemotron-3.5-super-vl-120b-a12b"
    public static let drawingModelID = "stepfun-ai/step-5-preview"

    /// A short, plain how-to or where-is question (text-only helpers use the fast model for these).
    public static func isSimple(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = q.split(separator: " ")
        guard !words.isEmpty, words.count <= 14 else { return false }
        let starts = ["how do i ", "how can i ", "how to ", "how do you ", "where is ", "where's ", "where are ", "where do i ",
                      "where can i ", "what's the shortcut", "what is the shortcut", "which button", "show me where", "how do we "]
        guard starts.contains(where: { q.hasPrefix($0) }) else { return false }
        let hard = ["why", "explain", "compare", "difference", "error", "wrong", "not working", "doesn't work", "won't",
                    "draw", "write", "summar", "should i", "best way", "recommend", "fix", "broken", "translate", "code"]
        return !hard.contains { q.contains($0) }
    }

    /// The NVIDIA models to try, in order, for `question` (the other configured fallbacks after the pair).
    public static func models(for question: String, fallbacks: [String]) -> [String] {
        let pair = [strongModelID, fastModelID]
        return pair + fallbacks.filter { !pair.contains($0) }
    }
}
