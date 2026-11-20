import AppKit
import ApplicationServices
import WispCore

/// Does a `WebAction` in the default browser the way a person would, with the companion doing each step as it really
/// happens: it looks at the screen (Accessibility), clicks the browser in the Dock (or finds it in the Apps launcher),
/// clicks the address bar as a new tab opens, types (checking what the field really holds), presses Return, and on a
/// site finds its search box and searches there. If a step can't be done, the page opens directly instead.
@MainActor
public final class WebActor {
    private let overlay: OverlayController?
    /// Test hook: each step's name (never the query).
    nonisolated(unsafe) public static var trace: ((String) -> Void)?

    public init(overlay: OverlayController?) {
        self.overlay = overlay
    }

    /// Runs the action; returns what to say afterwards.
    public func run(_ action: WebAction) async -> String {
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let bundleID = Bundle(url: browserURL)?.bundleIdentifier else {
            NSWorkspace.shared.open(action.url)
            return action.spokenResult
        }
        let name = FileManager.default.displayName(atPath: browserURL.path).replacingOccurrences(of: ".app", with: "")
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first

        // Without Accessibility it can't see where things are or type: open the page plainly and say why.
        guard ComputerUsePermission.check() else {
            _ = await openDirectly(action, browserURL)
            return action.spokenResult + " " + ComputerUsePermission.note
        }

        // 1. Bring the browser up: click it in the Dock (it opens as the cursor clicks), or find it in the Apps launcher.
        if running?.isActive != true {
            let found = AppLocator.Found(url: browserURL, name: name, bundleID: bundleID)
            if !(await DockDriver.click(found, overlay: overlay)), !(await AppLauncher.open(found, overlay: overlay)) {
                AppLauncher.close()
                await Self.activate(browserURL)
            }
        }
        guard let pid = await Self.waitForFront(bundleID: bundleID) else { return await openDirectly(action, browserURL) }
        Log.app.info("web: browser in front"); Self.trace?("web: browser in front")
        try? await Task.sleep(for: .milliseconds(300))  // a just-opened window settles before the next look

        // 3. A new tab (Command-T) as the cursor clicks the address bar, then type and press Return.
        let barBefore = UIFinder.addressBar(pid: pid)?.center ?? Self.windowTopCenter(pid: pid) ?? Self.screenTopCenter()
        _ = await overlay?.pointAndClick(at: barBefore, label: "")
        guard InputDriver.press(InputDriver.tKey, flags: .maskCommand, to: pid) else { return await openDirectly(action, browserURL) }
        try? await Task.sleep(for: .milliseconds(350))
        let bar = UIFinder.addressBar(pid: pid)
        if let bar { UIFinder.activate(bar) } // the new tab's address bar has the keyboard already; make sure
        let typed: String
        switch action {
        case .search(let q): typed = q
        case .open(_, let url): typed = url.host ?? url.absoluteString
        case .siteSearch(let name, _, _): typed = WebAction.domain(forSite: name) ?? name.lowercased() + ".com"
        }
        guard await typeChecked(typed, into: bar?.element, pid: pid) else { return await openDirectly(action, browserURL) }
        try? await Task.sleep(for: .milliseconds(200))
        _ = await overlay?.pointAndClick(at: Vec2((bar?.center ?? barBefore).x + 2, (bar?.center ?? barBefore).y), label: String(typed.suffix(28)))
        guard InputDriver.press(InputDriver.returnKey, to: pid) else { return await openDirectly(action, browserURL) }
        Log.app.info("web: typed into the address bar"); Self.trace?("web: typed into the address bar")

        // 4. On a site: wait for the page, find its search box (clicking "Search" first if that's what shows), type, Return.
        guard case .siteSearch(_, let query, _) = action else { return action.spokenResult }
        var box: UIFinder.Found?
        for _ in 0..<40 {   // up to ~8 s for the page to load
            try? await Task.sleep(for: .milliseconds(200))
            if let found = UIFinder.pageSearch(pid: pid) { box = found; break }
        }
        if let first = box, !first.isTextField {
            _ = await overlay?.pointAndClick(at: first.center, label: "Search")
            UIFinder.activate(first)
            box = nil
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                if let found = UIFinder.pageSearch(pid: pid), found.isTextField { box = found; break }
            }
        }
        guard let field = box, field.isTextField else {
            Log.app.info("web: no search box found; opening the results page"); Self.trace?("web: no search box found; opening the results page")
            return await openDirectly(action, browserURL)
        }
        _ = await overlay?.pointAndClick(at: field.center, label: "")
        UIFinder.activate(field)
        try? await Task.sleep(for: .milliseconds(250))
        guard await typeChecked(query, into: field.element, pid: pid) else { return await openDirectly(action, browserURL) }
        try? await Task.sleep(for: .milliseconds(200))
        _ = await overlay?.pointAndClick(at: Vec2(field.center.x + 2, field.center.y), label: String(query.suffix(28)))
        _ = InputDriver.press(InputDriver.returnKey, to: pid)
        Log.app.info("web: searched on the site"); Self.trace?("web: searched on the site")
        return action.spokenResult
    }

    /// Types `text` (the companion's label following along), then reads the field back; if it doesn't hold the text,
    /// selects everything in it and types once more.
    private func typeChecked(_ text: String, into field: AXUIElement?, pid: pid_t) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 {
                Self.trace?("web: field didn't match, typing again")
                guard InputDriver.press(InputDriver.aKey, flags: .maskCommand, to: pid) else { return false }
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard await InputDriver.type(text, to: pid, onCharacter: { [overlay] n in overlay?.updatePointLabel(String(String(text.prefix(n)).suffix(28))) }) else { return false }
            try? await Task.sleep(for: .milliseconds(150))
            guard let field else { return true }
            let value = (AXHelpers.string(field, kAXValueAttribute) ?? "").lowercased()
            if value.isEmpty || value.contains(text.lowercased()) { return true } // some fields don't report their value
        }
        return false
    }

    /// The reliable way: the page opens in a new tab of the browser.
    private func openDirectly(_ action: WebAction, _ browserURL: URL) async -> String {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if (try? await NSWorkspace.shared.open([action.url], withApplicationAt: browserURL, configuration: config)) == nil {
            NSWorkspace.shared.open(action.url)
        }
        Log.app.info("web: opened directly"); Self.trace?("web: opened directly")
        return action.spokenResult
    }

    private static func activate(_ app: URL) async {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
    }

    // MARK: Where things are

    static func screenTopCenter() -> Vec2 {
        let v = NSScreen.main?.visibleFrame ?? .zero
        return Vec2(v.midX, v.maxY - 60)
    }

    /// Where the address bar usually is: near the top of the front window.
    static func windowTopCenter(pid: pid_t) -> Vec2? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let b = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 })?[kCGWindowBounds as String] as? [String: Double],
              let x = b["X"], let y = b["Y"], let w = b["Width"] else { return nil }
        return Vec2(x + w * 0.4, primaryHeight - (y + 52))
    }

    /// Waits (up to 5 s) until the browser is in front with a window; returns its process.
    public static func waitForFront(bundleID: String, timeout: Double = 5) async -> pid_t? {
        for _ in 0..<Int(timeout * 10) {
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                if list.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
                    return app.processIdentifier
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // In front without a window (some apps open none) still counts.
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID { return app.processIdentifier }
        return nil
    }

    // MARK: Accessibility helpers

    private static var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }
    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private static func children(_ e: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
        guard let v = attribute(e, name), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
    /// Top-left-based global frame.
    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
