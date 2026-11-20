import AppKit
import ApplicationServices
import WispCore

/// Real keyboard input for light computer use, sent only to one app and only while it is in front (so nothing is
/// ever typed into the wrong place). Needs the Accessibility permission (Better answers).
enum InputDriver {
    static var canType: Bool { AXIsProcessTrusted() }

    /// True while `pid` is the app in front.
    @MainActor static func isFront(_ pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    /// Types `text` into `pid`'s focused field, one character at a time; `onCharacter` runs after each (for the
    /// companion's label). Stops (returns false) if the app stops being in front.
    @MainActor
    static func type(_ text: String, to pid: pid_t, delay: Duration = .milliseconds(45), stillOK: (() -> Bool)? = nil,
                     onCharacter: (Int) -> Void = { _ in }) async -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        for (i, ch) in text.enumerated() {
            guard stillOK?() ?? isFront(pid) else { return false }
            var units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.flags = []
            up.flags = []
            down.postToPid(pid)
            up.postToPid(pid)
            onCharacter(i + 1)
            try? await Task.sleep(for: delay)
        }
        return true
    }

    /// One key (with modifiers) to `pid`, e.g. Return (36) or Command-T (17 + .maskCommand).
    @MainActor
    static func press(_ key: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t, stillOK: (() -> Bool)? = nil) -> Bool {
        guard stillOK?() ?? isFront(pid) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    static let returnKey: CGKeyCode = 36
    static let escapeKey: CGKeyCode = 53
    static let tKey: CGKeyCode = 17
    static let lKey: CGKeyCode = 37
    static let aKey: CGKeyCode = 0
}

/// Finding things inside an app through Accessibility (address bars, a web page's search box).
public enum UIFinder {
    public struct Found { public var element: AXUIElement; public var center: Vec2; public var isTextField: Bool }

    /// The browser's address bar in its front window.
    @MainActor public static func addressBar(pid: pid_t) -> Found? {
        find(pid: pid, maxDepth: 9) { role, text in
            (role == "AXTextField" || role == "AXComboBox") && (text.contains("address") || text.contains("smart search") || text.contains("url") || text.contains("location"))
        }
    }

    /// A search box on the page (inside the web content), or failing that a "Search" button or link that opens one.
    @MainActor public static func pageSearch(pid: pid_t) -> Found? {
        let field = find(pid: pid, maxDepth: 40, skipChrome: true) { role, text in
            (role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox" || role == "AXTextArea") && text.contains("search")
        }
        if let field { return field }
        return find(pid: pid, maxDepth: 40, skipChrome: true) { role, text in
            (role == "AXLink" || role == "AXButton" || role == "AXMenuItem") && (text == "search" || text.hasPrefix("search ") || text.hasSuffix(" search"))
        }
    }

    /// Breadth-first search of the front window. `skipChrome` starts inside the web page (AXWebArea).
    @MainActor
    private static func find(pid: pid_t, maxDepth: Int, skipChrome: Bool = false, where match: (String, String) -> Bool) -> Found? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chrome-based browsers only expose web content to Accessibility when asked.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        guard let window = AXHelpers.element(app, kAXFocusedWindowAttribute) ?? AXHelpers.children(app).first(where: { AXHelpers.string($0, kAXRoleAttribute) == "AXWindow" }) else { return nil }
        var queue: [(AXUIElement, Int, Bool)] = [(window, 0, !skipChrome)]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (node, depth, inPage) = queue.removeFirst()
            visited += 1
            let role = AXHelpers.string(node, kAXRoleAttribute) ?? ""
            let nowInPage = inPage || role == "AXWebArea"
            if nowInPage {
                let text = [kAXDescriptionAttribute, kAXTitleAttribute, "AXPlaceholderValue", kAXHelpAttribute, "AXIdentifier"]
                    .compactMap { AXHelpers.string(node, $0) }.joined(separator: " ").lowercased()
                    .trimmingCharacters(in: .whitespaces)
                if match(role, text), let f = AXHelpers.frame(node), f.width > 8, f.height > 8 {
                    return Found(element: node, center: AXHelpers.appKitCenter(f), isTextField: role != "AXLink" && role != "AXButton" && role != "AXMenuItem")
                }
            }
            if depth < maxDepth { queue += AXHelpers.children(node).map { ($0, depth + 1, nowInPage) } }
        }
        return nil
    }

    /// Clicks an element the Accessibility way (press, and focus for text fields).
    static func activate(_ found: Found) {
        if found.isTextField {
            AXUIElementSetAttributeValue(found.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else {
            AXUIElementPerformAction(found.element, kAXPressAction as CFString)
        }
    }
}

/// Opens an app that isn't in the Dock the way a person would: the Apps launcher, type its name, Return.
public enum AppLauncher {
    /// The launcher's panel is showing with its search field focused.
    public static var isPanelUp: Bool { focusedPanelField() != nil }
    /// For tests: each panel process, whether it has a window on screen, and its focused element's role.
    public static var debugState: String {
        panelBundles.flatMap { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).map { app in
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            let role = AXHelpers.element(ax, kAXFocusedUIElementAttribute).flatMap { AXHelpers.string($0, kAXRoleAttribute) } ?? "none"
            return "\(id.split(separator: ".").last ?? ""):win=\(hasVisibleWindow(app.processIdentifier)) focus=\(role) hidden=\(app.isHidden)"
        } }.joined(separator: " ")
    }

    /// Processes that show the launcher / Spotlight panel (macOS 27: com.apple.campo).
    static let panelBundles = ["com.apple.campo", "com.apple.Spotlight", "com.apple.apps.launcher"]

    /// The launcher's focused search field, if its panel is up.
    static func focusedPanelField() -> (pid_t, AXUIElement)? {
        for id in panelBundles {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isHidden && hasVisibleWindow(app.processIdentifier) {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(ax, 0.2)
                if let field = AXHelpers.element(ax, kAXFocusedUIElementAttribute),
                   ["AXTextField", "AXSearchField"].contains(AXHelpers.string(field, kAXRoleAttribute) ?? "") {
                    return (app.processIdentifier, field)
                }
            }
        }
        return nil
    }

    /// A window of `pid` is on screen (the panel is really showing).
    static func hasVisibleWindow(_ pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0.1
            && (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) > 200 }
    }

    static let launcherBundle = "com.apple.apps.launcher"

    /// The Apps launcher, step by step, each step after looking at the screen: the Apps button in the Dock (as the
    /// companion clicks it), the search field (click, then type the name), and the app in the results (click).
    @MainActor
    static func open(_ found: AppLocator.Found, overlay: OverlayController?) async -> Bool {
        guard InputDriver.canType, let launcher = NSWorkspace.shared.urlForApplication(withBundleIdentifier: launcherBundle) else { return false }
        // 1. The Apps button in the Dock; without one, the launcher opens as the companion "clicks" where it appears.
        let apps = AppLocator.Found(url: launcher, name: "Apps", bundleID: launcherBundle)
        var clicked = false
        if focusedPanelField() == nil, let item = DockDriver.item(for: apps, in: DockDriver.items()) {
            clicked = await DockDriver.click(item, label: item.title, overlay: overlay) { DockDriver.item(for: apps, in: $0) }
        }
        if !clicked, focusedPanelField() == nil {
            if let overlay {
                let v = NSScreen.main?.visibleFrame ?? .zero
                _ = await overlay.pointAndClick(at: Vec2(v.midX, v.maxY - v.height * 0.2), label: "Apps")
            }
            NSWorkspace.shared.open(launcher)
        }
        // 2. Wait until the panel is really up (and stays up) with its search field.
        guard var (pid, field) = await ensurePanel(launcher) else { WebActor.trace?("launcher: panel didn't open"); return false }
        WebActor.trace?("launcher: panel open")
        var stillOK = { [pid] in focusedPanelField()?.0 == pid }

        // 3. Click into the search field, then type the name (checked against what the field really holds).
        WebActor.trace?("launcher: to the search field")
        if let overlay, let f = AXHelpers.frame(field) {
            _ = await overlay.pointAndClick(at: Vec2(AXHelpers.appKitCenter(f).x - f.width * 0.25, AXHelpers.appKitCenter(f).y), label: "")
        }
        var typedOK = false
        for attempt in 0..<3 where !typedOK {
            // The panel closed under us (it can, on its own): bring it back and carry on.
            if !stillOK() {
                WebActor.trace?("launcher: panel closed, opening it again")
                guard let again = await ensurePanel(launcher) else { return false }
                (pid, field) = again
                stillOK = { [pid] in focusedPanelField()?.0 == pid }
            }
            AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
            try? await Task.sleep(for: .milliseconds(120))
            WebActor.trace?("launcher: typing the app name")
            guard await InputDriver.type(found.name, to: pid, delay: .milliseconds(70), stillOK: stillOK, onCharacter: { n in
                overlay?.updatePointLabel(String(found.name.prefix(n)))
            }) else { WebActor.trace?("launcher: lost the keyboard while typing"); continue }
            let value = AXHelpers.string(field, kAXValueAttribute) ?? ""
            typedOK = AppLocator.key(value) == AppLocator.key(found.name)
            if !typedOK { WebActor.trace?("launcher: field didn't match (try \(attempt + 1))") }
        }
        guard typedOK else { close(); return false }

        // 4. Find the app in the results, fly there, and open it as the companion clicks.
        var hit: (index: Int, frame: CGRect)?
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(100))
            if let h = resultCell(pid: pid, named: found) { hit = h; break }
        }
        guard let hit else { WebActor.trace?("launcher: app not in the results"); close(); return false }
        WebActor.trace?("launcher: result \(hit.index + 1)")
        if let overlay { _ = await overlay.pointAndClick(at: AXHelpers.appKitCenter(hit.frame), label: found.name) }
        guard stillOK() else { return false }
        if hit.index == 0 {
            // The top result is selected already: Return opens it (no need to move their pointer).
            _ = InputDriver.press(InputDriver.returnKey, to: pid, stillOK: stillOK)
        } else {
            await DockDriver.realClick(at: CGPoint(x: hit.frame.midX, y: hit.frame.midY))
        }
        WebActor.trace?("launcher: opened the result")
        return true
    }

    /// The launcher's panel, once it has been up for a moment. Opening the launcher toggles it, and macOS sometimes
    /// counts a just-closed panel as open, so when it doesn't appear it is opened once more.
    @MainActor
    private static func ensurePanel(_ launcher: URL) async -> (pid_t, AXUIElement)? {
        for attempt in 0..<3 {
            if attempt > 0 { NSWorkspace.shared.open(launcher) }
            var steady = 0
            for _ in 0..<18 {   // ~1.4 s
                if let p = focusedPanelField() {
                    steady += 1
                    if steady >= 3 { return p }   // up for ~160 ms: it's staying
                } else { steady = 0 }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        return nil
    }

    /// The launcher's result for the app: its position in the results grid and its frame (top-left global).
    @MainActor
    static func resultCell(pid: pid_t, named found: AppLocator.Found) -> (index: Int, frame: CGRect)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let wanted = AppLocator.key(found.name)
        var queue: [(AXUIElement, Int)] = AXHelpers.children(app).map { ($0, 0) }
        var cells = 0
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if AXHelpers.string(node, kAXRoleAttribute) == "AXCell" {
                let texts = AXHelpers.children(node).compactMap { AXHelpers.string($0, kAXValueAttribute) ?? AXHelpers.string($0, kAXTitleAttribute) }
                let names = texts.map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
                if names.contains(where: { AppLocator.key($0) == wanted }), let f = AXHelpers.frame(node), f.width > 8 { return (cells, f) }
                cells += 1
                continue
            }
            if depth < 12 { queue += AXHelpers.children(node).map { ($0, depth + 1) } }
        }
        return nil
    }

    /// Closes the launcher panel (Escape through the normal keyboard path, only while its field has the keyboard).
    static func close() {
        guard focusedPanelField() != nil else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: InputDriver.escapeKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: InputDriver.escapeKey, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
