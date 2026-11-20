import Foundation

/// What macOS says is in the front app: its controls (name, kind, state, position) and its menu commands. Read
/// through the Accessibility API at the moment the question starts, alongside the screenshot. It lets the model
/// know facts a picture can't show reliably (a greyed-out button, a timer that's already paused, a command that's
/// only in a menu) and gives exact positions to point at.
public struct UIContext: Codable, Sendable, Equatable {
    public struct Element: Codable, Sendable, Equatable {
        /// Plain kind: button, checkbox, switch, radio, tab, popup, field, slider, link, text, item, …
        public var kind: String
        public var label: String
        /// "on", "off", "selected", a slider/field value, … (nil when there's nothing to say)
        public var state: String?
        public var enabled: Bool
        /// Global AppKit points (origin at the bottom-left of the primary display), like CaptureRecord.
        public var frame: Rect

        public init(kind: String, label: String, state: String? = nil, enabled: Bool = true, frame: Rect) {
            self.kind = kind; self.label = label; self.state = state; self.enabled = enabled; self.frame = frame
        }
    }

    public struct MenuItem: Codable, Sendable, Equatable {
        public var menu: String
        public var title: String
        public var shortcut: String?
        public var enabled: Bool

        public init(menu: String, title: String, shortcut: String? = nil, enabled: Bool = true) {
            self.menu = menu; self.title = title; self.shortcut = shortcut; self.enabled = enabled
        }
    }

    public var appName: String
    public var windowTitle: String?
    public var elements: [Element]
    public var menus: [MenuItem]
    /// Text selected in the focused control (never from a password field), cut to `maxSelectedText` characters.
    public var selectedText: String?
    /// The control or text right under the mouse pointer.
    public var underPointer: Element?
    /// The front window is full screen (its menu bar is hidden until the pointer reaches the top edge).
    public var fullScreen: Bool?

    /// macOS reported nothing inside the window (many apps built on web technology don't): the screenshot is the
    /// only way to find its controls.
    public var windowUnreadable: Bool { !elements.contains { $0.kind != "menu" } }

    public init(appName: String, windowTitle: String? = nil, elements: [Element], menus: [MenuItem],
                selectedText: String? = nil, underPointer: Element? = nil) {
        self.appName = appName; self.windowTitle = windowTitle; self.elements = elements; self.menus = menus
        self.selectedText = selectedText; self.underPointer = underPointer
    }

    public var isEmpty: Bool { elements.isEmpty && menus.isEmpty && selectedText == nil && underPointer == nil }

    public static let maxSelectedText = 1200

    /// Selected text as sent: whitespace collapsed, cut at a word near the limit; nil when empty.
    public static func cleanSelection(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxSelectedText else { return collapsed }
        let cut = collapsed.prefix(maxSelectedText)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + " …"
    }
}

/// A control as the model sees it: position already in the model's coordinate space.
public struct ControlLine: Sendable, Equatable {
    public var kind: String
    public var label: String
    public var state: String?
    public var enabled: Bool
    public var x: Double
    public var y: Double

    public init(kind: String, label: String, state: String?, enabled: Bool, x: Double, y: Double) {
        self.kind = kind; self.label = label; self.state = state; self.enabled = enabled; self.x = x; self.y = y
    }
}

public enum UIContextFormat {
    /// Caps that keep the request small (a few hundred tokens) and fast.
    public static let maxControls = 90
    public static let maxMenuItems = 110

    /// Controls visible in the screenshot, converted to model coordinates and de-duplicated, in reading order
    /// (top to bottom, left to right), the way a person scans a window.
    public static func controlLines(_ context: UIContext, record: CaptureRecord, space: ModelCoordinateSpace) -> [ControlLine] {
        var seen = Set<String>()
        var lines: [ControlLine] = []
        // AppKit y grows upwards: higher on screen = larger maxY.
        let sorted = context.elements.sorted { a, b in
            abs(a.frame.maxY - b.frame.maxY) > 6 ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX
        }
        let display = record.displayFrame
        for e in sorted {
            let c = e.frame.center
            guard c.x >= display.minX, c.x < display.maxX, c.y >= display.minY, c.y < display.maxY else { continue }
            let image = record.imagePoint(fromGlobal: c)
            let (mx, my) = modelPoint(image, record: record, space: space)
            let key = "\(e.kind)|\(e.label.lowercased())|\(Int(mx / 8))|\(Int(my / 8))"
            guard seen.insert(key).inserted else { continue }
            lines.append(ControlLine(kind: e.kind, label: e.label, state: e.state, enabled: e.enabled, x: mx, y: my))
            if lines.count >= maxControls { break }
        }
        return lines
    }

    /// One element converted to the model's space (nil when it isn't on the screenshot's display).
    public static func controlLine(_ e: UIContext.Element, record: CaptureRecord, space: ModelCoordinateSpace) -> ControlLine? {
        let c = e.frame.center
        let display = record.displayFrame
        guard c.x >= display.minX, c.x < display.maxX, c.y >= display.minY, c.y < display.maxY else { return nil }
        let (mx, my) = modelPoint(record.imagePoint(fromGlobal: c), record: record, space: space)
        return ControlLine(kind: e.kind, label: e.label, state: e.state, enabled: e.enabled, x: mx, y: my)
    }

    /// The text added to the request.
    public static func text(appName: String, controls: [ControlLine], menus: [UIContext.MenuItem], space: ModelCoordinateSpace,
                            selectedText: String? = nil, underPointer: ControlLine? = nil,
                            fullScreen: Bool = false, windowUnreadable: Bool = false) -> String {
        var out: [String] = []
        if windowUnreadable {
            out.append("macOS can't see the controls inside \(appName)'s window, so the list below leaves them out: find them in the screenshot.")
        }
        if fullScreen {
            out.append("\(appName) is full screen, so its menu bar is hidden (it slides down when the pointer reaches the top edge). Show something visible in the window when there is one.")
        }
        if let p = underPointer {
            var line = "Under the mouse pointer: \(p.kind) \"\(p.label)\""
            if let state = p.state, !state.isEmpty { line += " (\(state))" }
            if !p.enabled { line += " (greyed out)" }
            out.append(line + " at \(format(p.x, space)), \(format(p.y, space))")
        }
        if let selectedText, !selectedText.isEmpty {
            out.append("Text they have selected in \(appName): \"\(selectedText)\"")
        }
        if !controls.isEmpty {
            out.append("Controls in \(appName), as macOS reports them (positions use the same coordinates as your answer):")
            for c in controls {
                var line = "- \(c.kind) \"\(c.label)\""
                if let state = c.state, !state.isEmpty { line += " (\(state))" }
                if !c.enabled { line += " (greyed out)" }
                line += " at \(format(c.x, space)), \(format(c.y, space))"
                out.append(line)
            }
        }
        if !menus.isEmpty {
            out.append("\(appName)'s menu bar:")
            var byMenu: [(String, [String])] = []
            for item in menus.prefix(maxMenuItems) {
                var entry = item.title
                if let s = item.shortcut, !s.isEmpty { entry += " \(s)" }
                if !item.enabled { entry += " (greyed out)" }
                if let i = byMenu.firstIndex(where: { $0.0 == item.menu }) { byMenu[i].1.append(entry) } else { byMenu.append((item.menu, [entry])) }
            }
            for (menu, entries) in byMenu { out.append("- \(menu): \(entries.joined(separator: ", "))") }
        }
        return out.joined(separator: "\n")
    }

    /// The control a visual should land on: same name (word for word, ignoring kind words like "button") and
    /// within `reach` (model units) of where the model pointed. Accessibility frames cover the control itself, so
    /// unlike text on screen this is safe for icon buttons.
    public static func matchingControl(label: String, near point: (Double, Double), in controls: [ControlLine], reach: Double) -> ControlLine? {
        let wanted = normalized(label)
        guard !wanted.isEmpty else { return nil }
        let same = controls.filter { normalized($0.label) == wanted }
        func distance(_ c: ControlLine) -> Double { ((c.x - point.0) * (c.x - point.0) + (c.y - point.1) * (c.y - point.1)).squareRoot() }
        guard let nearest = same.min(by: { distance($0) < distance($1) }) else { return nil }
        // Within reach: that control. Further away: the name still decides when it's (nearly) unique, because macOS
        // knows exactly where the control is and the model's coordinates are the weaker evidence.
        return distance(nearest) <= reach || same.count <= 2 ? nearest : nil
    }

    /// The label compared word for word (kind words like "button" and a leading "the" ignored).
    public static func normalizedLabel(_ s: String) -> String { normalized(s) }

    static func normalized(_ s: String) -> String {
        var words = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let kinds: Set<String> = ["button", "icon", "menu", "item", "tab", "link", "field", "option", "checkbox", "toggle", "switch"]
        while words.count > 1, let last = words.last, kinds.contains(last) { words.removeLast() }
        while words.count > 1, let first = words.first, first == "the" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    private static func format(_ v: Double, _ space: ModelCoordinateSpace) -> String {
        space == .normalizedUnit ? String(format: "%.3f", v) : String(Int(v.rounded()))
    }

    private static func modelPoint(_ image: Vec2, record: CaptureRecord, space: ModelCoordinateSpace) -> (Double, Double) {
        switch space {
        case .imagePixels: return (image.x, image.y)
        case .normalized1000: return (image.x / Double(record.sentPixels.width) * 1000, image.y / Double(record.sentPixels.height) * 1000)
        case .normalizedUnit: return (image.x / Double(record.sentPixels.width), image.y / Double(record.sentPixels.height))
        }
    }
}
