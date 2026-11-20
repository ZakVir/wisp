import Foundation

/// Light computer use: open an app, and at most one simple thing in it (one menu command, like File > New).
/// "Open Notes", "open Autodesk Fusion and start a new project", "open a new tab", "make a new folder in Finder".
/// Anything longer ("…and start making a 3D model") is not done for the user.
public struct AppAction: Equatable, Sendable {
    /// The app to open (nil: the app in front).
    public var app: String?
    /// One thing to do in it, in the user's words (nil: just open it).
    public var task: String?

    public init(app: String?, task: String?) { self.app = app; self.task = task }

    private static let frontTasks = #"^(?:open|make|create|start|add) (?:a |an )?new (?:tab|window|document|file|folder|note|private window|incognito window|message|email|event|reminder|playlist|project|page|sheet|slide|presentation)(?: (?:in|on) (?<app>[\w .+&'-]+?))?$"#

    public static func parse(_ question: String) -> AppAction? {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
            .replacingOccurrences(of: "’", with: "'")
        if let r = q.range(of: #"^(?i)(?:hey wisp,? |wisp,? )?(?:can you |could you |please |go ahead and |would you )*"#, options: .regularExpression) {
            q = String(q[r.upperBound...])
        }
        q = q.replacingOccurrences(of: #"(?i)\s+(?:for me|please)$"#, with: "", options: .regularExpression)
        let lower = q.lowercased()

        // "Open a new tab" (in the app in front, or "in Chrome").
        if let regex = try? NSRegularExpression(pattern: frontTasks),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let app = Range(m.range(withName: "app"), in: lower).map { String(lower[$0]) }
            let task = app.map { lower.replacingOccurrences(of: " in " + $0, with: "").replacingOccurrences(of: " on " + $0, with: "") } ?? lower
            return AppAction(app: app, task: task)
        }

        // "Open Fusion", "launch Autodesk Fusion and start a new project", "switch to Mail".
        guard let regex = try? NSRegularExpression(pattern: #"^(?:open(?: up)?|launch|start|run|bring up|switch to) (?:the )?(?:app )?(?<app>[\w .+&'-]+?)(?: app)?(?: and (?:then )?(?<task>.+))?$"#),
              let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let ra = Range(m.range(withName: "app"), in: q) else { return nil }
        let app = String(q[ra]).trimmingCharacters(in: .whitespaces)
        let appLower = app.lowercased()
        // Not an app: parts of the screen or things inside an app ("open the file menu", "open settings for this").
        let notApps = ["file", "menu", "file menu", "edit menu", "view menu", "this", "that", "it", "a file", "the file", "a new tab",
                       "a new window", "a link", "the link", "this link", "this file", "my browser", "the browser", "browser",
                       "a tab", "tab", "window", "folder", "document", "inspector", "sidebar", "preferences", "settings for this"]
        if notApps.contains(appLower) || appLower.hasSuffix(" menu") || appLower.hasPrefix("a ") || appLower.hasPrefix("my ") && appLower.split(separator: " ").count > 3 {
            return nil
        }
        let task = Range(m.range(withName: "task"), in: q).map { String(q[$0]).trimmingCharacters(in: .whitespaces) }
        return AppAction(app: app, task: task?.isEmpty == true ? nil : task)
    }

    /// Tasks that are more than one simple step ("start making a 3D model", "write an essay"): not done for the user.
    public static func isTooBig(_ task: String) -> Bool {
        let t = task.lowercased()
        let big = ["and then", ", then", " then ", "make a model", "3d model", "design ", "write ", "draw ", "edit the", "build ",
                   "fill in", "fill out", "send ", "buy ", "pay", "delete", "submit", "sign in", "log in", "post "]
        return big.contains { t.contains($0) } || t.split(separator: " ").count > 9
    }
}
