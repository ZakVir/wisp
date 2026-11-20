import Foundation

/// Whether a visual from the model is shown, and where. One place for the rules, used by the app (TurnPipeline)
/// and the correctness test (wisp-bench), so what is measured is what ships.
public enum VisualDecision {
    public struct Turn: Sendable {
        public var question: String
        /// The model labelled the question "other" (not about the screen).
        public var topicSaysOther: Bool
        /// The front app's controls in the model's coordinate space (empty without the Accessibility permission).
        public var controls: [ControlLine]
        /// How far (model units) a point may be from a control with its name and still mean that control.
        public var reach: Double
        /// The app's menu commands (only visible once a menu is open).
        public var menuCommands: [String]

        public init(question: String, topicSaysOther: Bool, controls: [ControlLine], reach: Double, menuCommands: [String] = []) {
            self.question = question; self.topicSaysOther = topicSaysOther; self.controls = controls; self.reach = reach
            self.menuCommands = menuCommands
        }
    }

    /// - Parameters:
    ///   - lastSentence: the spoken sentence the visual follows.
    ///   - textConfirms: whether the visual's label is written on screen near it (on-device text recognition).
    /// - Returns: the visual to show (a point may be moved onto the control it names), or nil to show nothing.
    public static func decide(_ event: AssistantEvent, after lastSentence: String, turn: Turn,
                              textConfirms: (AssistantEvent) -> Bool) -> AssistantEvent? {
        guard QuestionIntent.allowsPointing(turn.question) else { return nil }
        // "Draw a cat": drawing is the answer, wherever it goes; none of the pointing checks apply.
        if Drawing.isDrawRequest(turn.question) { return event }
        // A sentence saying it isn't there, or asking them what they mean, never comes with a point.
        if QuestionIntent.deniesPresence(lastSentence) || QuestionIntent.asksBack(lastSentence) { return nil }
        let (screen, inner) = event.screenAndEvent
        let label = inner.label ?? ""
        let control = screen == 0 ? matchingControl(inner, label: label, turn: turn) : nil
        // A point at a menu command ("Duplicate") that is no control on screen points at nothing: the command is only
        // inside its menu. (The menu's title, "File", is on screen and is one of the controls.)
        if control == nil, !turn.controls.isEmpty {
            let name = UIContextFormat.normalizedLabel(label)
            if !name.isEmpty, turn.menuCommands.contains(where: { UIContextFormat.normalizedLabel($0) == name }),
               !turn.controls.contains(where: { UIContextFormat.normalizedLabel($0.label) == name }) {
                return nil
            }
        }
        if turn.topicSaysOther {
            // Labelled "not about the screen" but pointed anyway: kept only when its own sentence names the thing and
            // the thing is really there (one of the app's controls, or its name written on screen next to the point).
            guard QuestionIntent.sentenceNames(label: label, in: lastSentence), control != nil || textConfirms(event) else { return nil }
        }
        // A point on a named control lands on the control itself (macOS knows exactly where it is).
        if let control, case .point = inner {
            return .point(x: control.x, y: control.y, label: label)
        }
        return event
    }

    private static func matchingControl(_ event: AssistantEvent, label: String, turn: Turn) -> ControlLine? {
        guard !turn.controls.isEmpty, let p = anchor(event) else { return nil }
        return UIContextFormat.matchingControl(label: label, near: p, in: turn.controls, reach: turn.reach)
    }

    public static func anchor(_ event: AssistantEvent) -> (Double, Double)? {
        switch event {
        case .point(let x, let y, _): return (x, y)
        case .circle(let x, let y, let w, let h, _): return (x + w / 2, y + h / 2)
        case .underline(let x1, let y1, let x2, let y2, _): return ((x1 + x2) / 2, (y1 + y2) / 2)
        case .arrow(_, _, let x2, let y2, _): return (x2, y2)
        case .path(let points, _): return points.first.map { ($0.x, $0.y) }
        default: return nil
        }
    }

    /// The greyed-out control (as macOS reports it) that a shown visual lands on, if any.
    public static func greyedOutTarget(_ shown: AssistantEvent, turn: Turn) -> ControlLine? {
        let (screen, inner) = shown.screenAndEvent
        guard screen == 0, let p = anchor(inner) else { return nil }
        let name = UIContextFormat.normalizedLabel(inner.label ?? "")
        let near = turn.controls.filter { c in
            !c.enabled && ((c.x - p.0) * (c.x - p.0) + (c.y - p.1) * (c.y - p.1)).squareRoot() <= turn.reach / 6
        }
        return near.first { UIContextFormat.normalizedLabel($0.label) == name } ?? near.first
    }

    /// One short sentence when the answer shows a control that can't be used right now and doesn't say so itself
    /// (small models often say "click Back" when Back is greyed out). Facts from macOS, not the model's guess.
    public static func greyedOutNote(labels: [String], answer: [String]) -> String? {
        guard let label = labels.first(where: { !$0.isEmpty }) else { return nil }
        let text = answer.joined(separator: " ").lowercased().replacingOccurrences(of: "’", with: "'")
        let alreadySaid = ["greyed", "grayed", "dimmed", "unavailable", "not available", "isn't available", "disabled",
                           "can't be used", "cannot be used", "can't use", "not active", "inactive"]
        if alreadySaid.contains(where: { text.contains($0) }) { return nil }
        return "\(label) is greyed out right now, so it can't be used yet."
    }

    /// 12 % of the image's long edge, in the model's units.
    public static func reach(space: ModelCoordinateSpace, sentPixels: PixelSize) -> Double {
        switch space {
        case .imagePixels: return Double(max(sentPixels.width, sentPixels.height)) * 0.12
        case .normalized1000: return 120
        case .normalizedUnit: return 0.12
        }
    }
}
