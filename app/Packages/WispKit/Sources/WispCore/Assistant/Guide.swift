import Foundation

/// Step-by-step guidance. After a how-to answer, Wisp watches for the person to do the step (a click anywhere, a
/// shortcut, Return, typing), waits for the screen to settle, then looks again (a fresh screenshot) and gives the
/// next step, until the model says the task is done, the person stops it, or it goes quiet for a while.
public struct GuideSession: Equatable, Sendable {
    public static let maxSteps = 12
    /// A click this close (points) to the target counts as using it.
    public static let clickReach: Double = 70
    /// Guidance ends after this long without anything happening.
    public static let idleTimeout: TimeInterval = 180

    /// Something the person did while a step was showing. What they typed is never recorded.
    public enum UserAction: Equatable, Sendable {
        case click(onTarget: Bool)
        /// A key or shortcut by name ("Return", "Command-N").
        case key(String)
        case typing
    }

    /// A finished step: what Wisp asked for, and what the person did.
    public struct Step: Equatable, Sendable {
        public var said: String
        public var did: String
    }

    public var goal: String
    public private(set) var steps: [Step] = []
    /// What Wisp asked them to do now (the spoken answer).
    public private(set) var current: String
    /// Where the current step points (AppKit global), if it points.
    public private(set) var target: Vec2?
    public private(set) var targetLabel: String
    /// What they've done since the current step was shown.
    public private(set) var actions: [UserAction] = []

    public init(goal: String, said: String, target: Vec2?, targetLabel: String) {
        self.goal = goal; self.current = said; self.target = target; self.targetLabel = targetLabel
    }

    /// 1 for the first step.
    public var stepNumber: Int { steps.count + 1 }
    /// No more steps after this one.
    public var isAtLimit: Bool { stepNumber >= Self.maxSteps }
    public var hasActed: Bool { !actions.isEmpty }
    /// They clicked the highlighted control.
    public var clickedTarget: Bool { actions.contains(.click(onTarget: true)) }
    /// A next step pointing here (AppKit global) at `label` only repeats the step they already did by clicking it.
    public func isRepeat(of point: Vec2?, label: String) -> Bool {
        guard clickedTarget else { return false }
        if let point, let target, point.distance(to: target) <= Self.clickReach { return true }
        let a = UIContextFormat.normalizedLabel(label), b = UIContextFormat.normalizedLabel(targetLabel)
        return !a.isEmpty && a == b
    }

    /// They used what the step showed (clicked the highlighted control) or pressed a key: the step was done, even
    /// if the screen barely changes.
    public var usedTheStep: Bool {
        actions.contains { action in
            switch action {
            case .click(let onTarget): return onTarget
            case .key: return true
            case .typing: return false
            }
        }
    }

    /// Records a click (on the highlighted spot or elsewhere).
    public mutating func clicked(at point: Vec2) {
        let onTarget = target.map { point.distance(to: $0) <= Self.clickReach } ?? false
        record(.click(onTarget: onTarget))
    }

    public mutating func record(_ action: UserAction) {
        if action == .typing, actions.last == .typing { return }
        if actions.count >= 8 { actions.removeFirst() }
        actions.append(action)
    }

    /// The next step was given: the current one is done.
    public mutating func advance(said: String, target: Vec2?, targetLabel: String) {
        steps.append(Step(said: current, did: actionsText))
        current = said
        self.target = target
        self.targetLabel = targetLabel
        actions = []
    }

    /// The same step was given again (it hadn't happened yet): keep the step, start watching afresh.
    public mutating func repeatStep(said: String, target: Vec2?, targetLabel: String) {
        current = said
        self.target = target
        self.targetLabel = targetLabel
        actions = []
    }

    /// "clicked the highlighted Export, then pressed Return" (what they did since the step was shown).
    public var actionsText: String {
        guard !actions.isEmpty else { return "did nothing yet" }
        let label = targetLabel.isEmpty ? "spot" : targetLabel
        let parts = actions.map { action -> String in
            switch action {
            case .click(true): return "clicked the highlighted \(label)"
            case .click(false): return "clicked somewhere else"
            case .key(let name): return "pressed \(name)"
            case .typing: return "typed something"
            }
        }
        return parts.joined(separator: ", then ")
    }

    /// Questions that ask how to get something done (a task with steps), as opposed to "what's this" or facts.
    public static func isTask(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let starts = ["how do i", "how can i", "how to", "how would i", "how should i", "how do we", "how do you",
                      "where do i", "where can i", "help me", "walk me through", "show me how", "i want to", "i need to",
                      "i'd like to", "can you show me how", "can you help me", "can you walk me", "teach me", "guide me",
                      "what do i do to", "what do i click to", "how am i supposed to"]
        return starts.contains { q.hasPrefix($0) }
    }

    /// During a walkthrough, things people say that mean "go on" ("what now?", "I did it", "next").
    public static func isContinuation(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "'")).inverted).joined()
            .split(separator: " ").joined(separator: " ")
        let exact: Set<String> = ["next", "ok", "okay", "done", "continue", "go on", "keep going", "and then", "then what",
                                  "now what", "what now", "what next", "whats next", "what's next", "ok what now", "okay what now",
                                  "okay now what", "ok now what", "okay next", "ok next", "got it", "next one", "what else",
                                  "i did it", "i did that", "i clicked it", "i clicked that", "it's open", "its open", "done now",
                                  "okay done", "ok done", "all right", "alright", "yep", "yes"]
        if exact.contains(q) { return true }
        let starts = ["what's the next step", "whats the next step", "what is the next step", "what do i do now",
                      "what do i do next", "what should i do now", "what should i do next", "next step", "okay what's next",
                      "ok what's next", "okay what do i", "ok what do i", "i did it", "i clicked it", "i've done that",
                      "done what's next", "done whats next", "what's after that", "what comes next", "then what do i"]
        return starts.contains { q.hasPrefix($0) }
    }

    /// Goes with a how-to question's first answer: the model says whether more steps follow.
    public static let firstStepText = """
    If this is something they want to do on the screen now, they may do it step by step while you watch. Say what \
    to do now (you can name the steps after it in a few words) and show the first thing to use. Then end the reply \
    with one more line: "STEPS: more" if there's more to do after this step, or "STEPS: done" if this step finishes \
    it or it isn't a task to do on the screen.
    """

    /// Goes with the request for the next step (with a fresh screenshot).
    public var requestText: String {
        var lines = ["They're doing a task step by step while you watch: \"\(goal)\"."]
        if !steps.isEmpty {
            lines.append("Steps so far:")
            for (i, step) in steps.suffix(6).enumerated() {
                lines.append("\(i + 1). You said: \"\(step.said)\" They \(step.did).")
            }
        }
        lines.append("Just now you said: \"\(current)\" Since then they \(actionsText). The screenshot shows the screen now.")
        if clickedTarget {
            // Stated as a fact: a model looking at a screen that hasn't caught up yet would otherwise ask again.
            let used = targetLabel.isEmpty ? "what you showed" : "\"\(targetLabel)\", the control you showed"
            lines.append("""
            They clicked \(used), so that step is done: don't ask them to do it again. Give the step after it and show \
            where it is. If what it opens isn't on the screen yet, say what to do in it once it appears and show \
            nothing.
            """)
        }
        lines.append("""
        Look at it carefully. If the task is finished, say so in a few words and show nothing. If they clearly did \
        something else and the step still needs doing, say it once more in different words and show it again. \
        Otherwise give only the next step: one or two short sentences, and show where it is. End with "STEPS: more" \
        if more steps follow, or "STEPS: done" if the task is finished or this step finishes it.
        """)
        return lines.joined(separator: "\n")
    }
}

/// A tiny greyscale thumbnail of the screen, for telling whether anything changed (never sent anywhere).
public struct ScreenFingerprint: Equatable, Sendable {
    public static let width = 64, height = 40
    public var pixels: [UInt8]

    public init(pixels: [UInt8]) { self.pixels = pixels }

    /// Share of cells that changed noticeably (0…1).
    public func difference(to other: ScreenFingerprint) -> Double {
        guard pixels.count == other.pixels.count, !pixels.isEmpty else { return 1 }
        var changed = 0
        for i in pixels.indices where abs(Int(pixels[i]) - Int(other.pixels[i])) > 12 { changed += 1 }
        return Double(changed) / Double(pixels.count)
    }

    /// The screen looks different (more than a blinking caret or a clock tick).
    public func changed(from other: ScreenFingerprint) -> Bool { difference(to: other) > 0.004 }
}
