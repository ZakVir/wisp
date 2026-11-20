import AppKit
import ApplicationServices
import WispCore

/// Reads the front app's window controls and menu bar through the Accessibility API (needs the optional
/// Accessibility permission). Runs off the main thread when a question starts; gives up at its time budget and
/// returns whatever it has. Never reads passwords or what's typed in text fields.
public enum UIContextReader {
    public static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow Accessibility" prompt (and lists Wisp in System Settings).
    public static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt (a C global Swift 6 won't read from a nonisolated context).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Asks an app built on Electron (Claude, Slack, VS Code, Discord…) to report what's inside its windows, which
    /// such apps only do when asked. It builds that list in the background, so this is called as soon as the app
    /// comes to the front, well before a question. Other apps ignore the request.
    public static func exposeControls(pid: pid_t) {
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// - Parameters:
    ///   - pid: the front app (never Wisp itself).
    ///   - primaryHeight: height of the primary display in points (to convert to AppKit coordinates).
    ///   - pointer: the mouse pointer in Accessibility coordinates (top-left origin), for what's under it.
    ///   - privateApps: bundle identifiers Wisp must not look at (nothing under the pointer is read from them).
    public static func read(pid: pid_t, appName: String, primaryHeight: Double, pointer: CGPoint? = nil,
                            privateApps: Set<String> = [], budget: TimeInterval = 0.6) -> UIContext? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        // First the two things "this" most often means: the selected text and what's under the pointer.
        let selected = selectedText(app)
        let hovered = pointer.flatMap { underPointer($0, primaryHeight: primaryHeight, privateApps: privateApps) }
        let window = element(app, kAXFocusedWindowAttribute) ?? elements(app, kAXWindowsAttribute).first
        var out: [UIContext.Element] = []
        var title: String?
        if let window {
            title = string(window, kAXTitleAttribute)
            let windowFrame = frame(window, primaryHeight: primaryHeight)
            // Breadth-first: the toolbar and the window's main controls come before deep table contents.
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var visited = 0, texts = 0
            while !queue.isEmpty, visited < 1500, out.count < 160, ProcessInfo.processInfo.systemUptime < deadline {
                let (node, depth) = queue.removeFirst()
                visited += 1
                if let e = describe(node, primaryHeight: primaryHeight, within: windowFrame) {
                    if e.kind == "text" { texts += 1; if texts <= 40 { out.append(e) } } else { out.append(e) }
                }
                if depth < 30 { queue += elements(node, kAXChildrenAttribute).map { ($0, depth + 1) } }
            }
        }
        // The menu bar's titles (File, Edit, …) are on screen too: listed with their exact positions. Not when the
        // window is full screen: then the menu bar is hidden and pointing there would point at nothing.
        let fullScreen = window.map { (attribute($0, "AXFullScreen") as? Bool) == true } ?? false
        if !fullScreen, let bar = element(app, kAXMenuBarAttribute) {
            for (index, top) in elements(bar, kAXChildrenAttribute).enumerated() where index > 0 {
                guard let title = string(top, kAXTitleAttribute), !title.isEmpty, title != "Help",
                      let f = frame(top, primaryHeight: primaryHeight) else { continue }
                out.append(UIContext.Element(kind: "menu", label: title, frame: f))
            }
        }
        let windowTitles = Set(elements(app, kAXWindowsAttribute).compactMap { string($0, kAXTitleAttribute) })
        let menus = ProcessInfo.processInfo.systemUptime < deadline ? menuItems(app, deadline: deadline, windowTitles: windowTitles) : []
        var context = UIContext(appName: appName, windowTitle: title, elements: out, menus: menus,
                                selectedText: selected, underPointer: hovered)
        context.fullScreen = fullScreen
        return context
    }

    // MARK: Shortcuts

    /// Every menu command of the app that has a keyboard shortcut (for the Shortcuts card), in menu order.
    public static func menuShortcuts(pid: pid_t, budget: TimeInterval = 2.0) -> [UIContext.MenuItem] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        let windowTitles = Set(elements(app, kAXWindowsAttribute).compactMap { string($0, kAXTitleAttribute) })
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        var out: [UIContext.MenuItem] = []
        for (index, top) in elements(bar, kAXChildrenAttribute).enumerated() where index > 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let menuTitle = string(top, kAXTitleAttribute), !menuTitle.isEmpty, menuTitle != "Help",
                  let menu = elements(top, kAXChildrenAttribute).first else { continue }
            for item in elements(menu, kAXChildrenAttribute) {
                guard let title = string(item, kAXTitleAttribute), !title.isEmpty, let keys = shortcut(item) else { continue }
                if title == "Services" || title.hasPrefix("Move to ") || windowTitles.contains(title) { continue }
                out.append(UIContext.MenuItem(menu: menuTitle, title: title, shortcut: keys,
                                              enabled: (attribute(item, kAXEnabledAttribute) as? Bool) ?? true))
                if out.count >= 400 { return out }
            }
        }
        return out
    }

    // MARK: Selection and pointer

    /// The front app's selected text in full (up to `limit` characters), for reading aloud. Nil without the
    /// permission, in a password field, or when nothing is selected.
    public static func fullSelection(pid: pid_t, limit: Int = 8000) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let focused = element(app, kAXFocusedUIElementAttribute),
              string(focused, kAXRoleAttribute) != "AXSecureTextField", string(focused, kAXSubroleAttribute) != "AXSecureTextField",
              let text = string(focused, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return String(text.prefix(limit))
    }

    /// The focused control's selected text. Never from a password field (macOS doesn't expose it there either).
    private static func selectedText(_ app: AXUIElement) -> String? {
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        if string(focused, kAXRoleAttribute) == "AXSecureTextField" || string(focused, kAXSubroleAttribute) == "AXSecureTextField" {
            return nil
        }
        return UIContext.cleanSelection(string(focused, kAXSelectedTextAttribute))
    }

    /// The nearest describable control (or text) at the pointer, looking up a few parents (an icon inside a button).
    /// What's under the pointer right now (the key-up check: people often move onto the thing while talking).
    public static func elementUnderPointer(_ point: CGPoint, primaryHeight: Double, privateApps: Set<String>) -> UIContext.Element? {
        guard AXIsProcessTrusted() else { return nil }
        return underPointer(point, primaryHeight: primaryHeight, privateApps: privateApps)
    }

    private static func underPointer(_ point: CGPoint, primaryHeight: Double, privateApps: Set<String>) -> UIContext.Element? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, var node = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(node, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, privateApps.contains(id) { return nil }
        for _ in 0..<4 {
            if let e = describe(node, primaryHeight: primaryHeight, within: nil), e.kind != "password field" { return e }
            guard let parent = element(node, kAXParentAttribute) else { break }
            node = parent
        }
        return nil
    }

    // MARK: Controls

    private static let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    private static func describe(_ node: AXUIElement, primaryHeight: Double, within window: Rect?) -> UIContext.Element? {
        guard let role = string(node, kAXRoleAttribute) else { return nil }
        let subrole = string(node, kAXSubroleAttribute) ?? ""
        if windowButtons.contains(subrole) { return nil }
        let kind: String
        var state: String?
        switch role {
        case "AXButton": kind = "button"
        case "AXMenuButton": kind = "menu button"
        case "AXPopUpButton": kind = "popup"; state = string(node, kAXValueAttribute).flatMap(short)
        case "AXCheckBox":
            kind = subrole == "AXSwitch" ? "switch" : "checkbox"
            state = number(node, kAXValueAttribute).map { $0 == 0 ? "off" : "on" }
        case "AXRadioButton":
            kind = "tab"
            if number(node, kAXValueAttribute) == 1 { state = "selected" }
        case "AXSlider": kind = "slider"; state = number(node, kAXValueAttribute).map { String(format: "%g", $0) }
        case "AXLink": kind = "link"
        case "AXTextField", "AXSearchField", "AXComboBox", "AXTextArea":
            kind = role == "AXSearchField" ? "search field" : "text field" // the typed value is never read
        case "AXSecureTextField": kind = "password field"
        case "AXStaticText":
            kind = "text"
            guard let text = string(node, kAXValueAttribute).flatMap(short) else { return nil }
            guard let f = frame(node, primaryHeight: primaryHeight), f.width > 2, f.height > 2 else { return nil }
            if let window, !intersects(f, window) { return nil }
            return UIContext.Element(kind: kind, label: text, frame: f)
        case "AXIncrementor": kind = "stepper"
        case "AXColorWell": kind = "color well"
        case "AXDisclosureTriangle": kind = "disclosure"
        default: return nil
        }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute]
            .lazy.compactMap { string(node, $0).flatMap(short) }.first ?? ""
        guard !label.isEmpty else { return nil }
        guard let f = frame(node, primaryHeight: primaryHeight), f.width > 2, f.height > 2 else { return nil }
        if let window, !intersects(f, window) { return nil }
        let enabled = (attribute(node, kAXEnabledAttribute) as? Bool) ?? true
        return UIContext.Element(kind: kind, label: label, state: state, enabled: enabled, frame: f)
    }

    // MARK: Menus

    /// Menu commands, minus what says nothing useful or something personal: the Help menu, Services, other devices
    /// ("Move to Zakir's iPad") and the Window menu's list of open windows (their titles can name people or files).
    private static func menuItems(_ app: AXUIElement, deadline: TimeInterval, windowTitles: Set<String>) -> [UIContext.MenuItem] {
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        var out: [UIContext.MenuItem] = []
        for (index, top) in elements(bar, kAXChildrenAttribute).enumerated() {
            guard ProcessInfo.processInfo.systemUptime < deadline, out.count < UIContextFormat.maxMenuItems else { break }
            if index == 0 { continue } // the Apple menu: the same in every app
            guard let menuTitle = string(top, kAXTitleAttribute), !menuTitle.isEmpty, menuTitle != "Help",
                  let menu = elements(top, kAXChildrenAttribute).first else { continue }
            for item in elements(menu, kAXChildrenAttribute) {
                guard let title = string(item, kAXTitleAttribute), !title.isEmpty else { continue } // separators
                if title == "Services" || title.hasPrefix("Move to ") || title.hasPrefix("<<") || windowTitles.contains(title)
                    || (menuTitle == "Window" && title.contains(" | ")) { continue }
                let enabled = (attribute(item, kAXEnabledAttribute) as? Bool) ?? true
                out.append(UIContext.MenuItem(menu: menuTitle, title: title, shortcut: shortcut(item), enabled: enabled))
                if out.count >= UIContextFormat.maxMenuItems { break }
            }
        }
        return out
    }

    private static func shortcut(_ item: AXUIElement) -> String? {
        guard let char = string(item, kAXMenuItemCmdCharAttribute), !char.isEmpty else { return nil }
        let mods = Int(number(item, kAXMenuItemCmdModifiersAttribute) ?? 0)
        var s = ""
        if mods & 4 != 0 { s += "⌃" }
        if mods & 2 != 0 { s += "⌥" }
        if mods & 1 != 0 { s += "⇧" }
        if mods & 8 == 0 { s += "⌘" }
        return s + char.uppercased()
    }

    // MARK: Helpers

    private static func short(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty, t.count <= 60 else { return nil }
        return t
    }

    private static func intersects(_ a: Rect, _ b: Rect) -> Bool {
        a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }

    private static func number(_ e: AXUIElement, _ name: String) -> Double? { (attribute(e, name) as? NSNumber)?.doubleValue }

    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let v = attribute(e, name), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    /// AX frames are global with a top-left origin; converted to AppKit global coordinates (bottom-left origin).
    private static func frame(_ e: AXUIElement, primaryHeight: Double) -> Rect? {
        guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return Rect(x: point.x, y: primaryHeight - point.y - size.height, width: size.width, height: size.height)
    }
}
