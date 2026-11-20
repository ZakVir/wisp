import AppKit
import ApplicationServices
import WispCore

/// Clicks things in the Dock the way a person would. It looks first (where the Dock's items are right now, through
/// Accessibility); when the Dock is hidden (a full-screen app, or auto-hide) it brings it up by pushing the pointer
/// against its edge, reads the positions again once it has slid in, and only then flies the companion there. The
/// item opens exactly as the companion clicks.
@MainActor
enum DockDriver {
    struct Item { var element: AXUIElement; var title: String; var url: URL?; var frame: CGRect } // frame: top-left global

    /// The Dock's app items as they are now.
    static func items() -> [Item] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var out: [Item] = []
        for list in AXHelpers.children(app) where AXHelpers.string(list, kAXRoleAttribute) == "AXList" {
            for item in AXHelpers.children(list) {
                guard let title = AXHelpers.string(item, kAXTitleAttribute), let f = AXHelpers.frame(item), f.width > 4 else { continue }
                let url = AXHelpers.attribute(item, kAXURLAttribute).flatMap { $0 as? URL }
                out.append(Item(element: item, title: title, url: url, frame: f))
            }
        }
        return out
    }

    /// The Dock item for an app (by its location on disk, or its name).
    static func item(for app: AppLocator.Found, in list: [Item]) -> Item? {
        let path = app.url.standardizedFileURL.path
        return list.first { $0.url?.standardizedFileURL.path == path }
            ?? list.first { $0.title.caseInsensitiveCompare(app.name) == .orderedSame }
    }

    /// On a display (the Dock isn't hidden): its centre is on screen with room around it (a magnified icon may
    /// reach past the edge).
    static func isShowing(_ f: CGRect) -> Bool {
        displays().contains { $0.insetBy(dx: 4, dy: 4).contains(CGPoint(x: f.midX, y: f.midY)) }
    }

    /// Display bounds in the same top-left global space as Accessibility.
    static func displays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Clicks the app's Dock item with the companion. False if it isn't in the Dock or the Dock can't be shown.
    static func click(_ app: AppLocator.Found, overlay: OverlayController?) async -> Bool {
        guard let first = item(for: app, in: items()) else { trace("dock: the app isn't in the Dock"); return false }
        return await click(first, label: app.name, overlay: overlay) { item(for: app, in: $0) }
    }

    static func click(_ first: Item, label: String, overlay: OverlayController?, refind: ([Item]) -> Item?) async -> Bool {
        var target = first
        var restore: CGPoint?
        if !isShowing(target.frame) {
            trace("dock: hidden, bringing it up")
            restore = CGEvent(source: nil)?.location
            guard let shown = await reveal(near: target.frame, refind: refind) else {
                trace("dock: couldn't bring it up")
                if let restore { movePointer(to: restore) }
                return false
            }
            target = shown
        }
        trace("dock: clicking the item")
        if let overlay { _ = await overlay.pointAndClick(at: AXHelpers.appKitCenter(target.frame), label: label) }
        // Re-read at the click: the Dock may have shifted (magnification) while the companion flew.
        let now = refind(items()) ?? target
        let ok = AXUIElementPerformAction(now.element, kAXPressAction as CFString) == .success
        if let restore {
            try? await Task.sleep(for: .milliseconds(450))
            movePointer(to: restore)
        }
        return ok
    }

    /// Pushes the pointer against the Dock's screen edge until it slides in, then rests it on the item (the Dock
    /// stays up while the pointer is on it, and the item stops moving). Returns the item where it is now.
    private static func reveal(near hidden: CGRect, refind: ([Item]) -> Item?) async -> Item? {
        let edge = (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")) ?? "bottom"
        let center = CGPoint(x: hidden.midX, y: hidden.midY)
        let screens = displays()
        guard let display = screens.min(by: { distance($0, center) < distance($1, center) }) else { return nil }
        let push: (CGPoint, Int64, Int64)
        switch edge {
        case "left": push = (CGPoint(x: display.minX, y: min(max(center.y, display.minY + 2), display.maxY - 2)), -6, 0)
        case "right": push = (CGPoint(x: display.maxX - 1, y: min(max(center.y, display.minY + 2), display.maxY - 2)), 6, 0)
        default: push = (CGPoint(x: min(max(center.x, display.minX + 2), display.maxX - 2), y: display.maxY - 1), 0, 6)
        }
        // Glide in toward the edge (the Dock reacts to a pointer arriving there, not one dropped on it), then push.
        for i in 0..<10 {
            let k = Double(10 - i) * 4
            let p = CGPoint(x: push.0.x - Double(push.1 == 0 ? 0 : (push.1 > 0 ? k : -k)), y: push.0.y - (push.2 > 0 ? k : 0))
            movePointer(to: p, dx: push.1 == 0 ? 0 : (push.1 > 0 ? 4 : -4), dy: push.2 > 0 ? 4 : 0)
            try? await Task.sleep(for: .milliseconds(12))
        }
        for round in 0..<3 {
            for _ in 0..<20 {
                movePointer(to: push.0, dx: push.1, dy: push.2)
                try? await Task.sleep(for: .milliseconds(12))
            }
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(60))
                if let shown = refind(items()), isShowing(shown.frame) {
                    // Rest on the item so it stays put, and let the slide-in finish.
                    movePointer(to: CGPoint(x: shown.frame.midX, y: shown.frame.midY))
                    try? await Task.sleep(for: .milliseconds(260))
                    let settled = refind(items()) ?? shown
                    trace("dock: up after \(round + 1) push(es)")
                    return isShowing(settled.frame) ? settled : nil
                }
            }
        }
        return nil
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Moves the real pointer (top-left global), with a push delta so edge-triggered UI (the Dock) notices.
    static func movePointer(to p: CGPoint, dx: Int64 = 0, dy: Int64 = 0) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: dx)
        e.setIntegerValueField(.mouseEventDeltaY, value: dy)
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    /// A real click at `p` (top-left global); the pointer goes back where it was.
    static func realClick(at p: CGPoint) async {
        let back = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        movePointer(to: p)
        try? await Task.sleep(for: .milliseconds(40))
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(30))
        }
        if let back {
            try? await Task.sleep(for: .milliseconds(120))
            movePointer(to: back)
        }
    }

    static func trace(_ s: String) { Log.app.info("\(s, privacy: .public)"); WebActor.trace?(s) }
}

/// Light computer use needs the Accessibility permission (to see where things are and to click and type). Without it
/// Wisp says so and asks once, instead of pretending.
@MainActor
enum ComputerUsePermission {
    private static var asked = false

    /// True when allowed; otherwise shows macOS's prompt (once per launch) and returns false.
    static func check() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !asked { asked = true; UIContextReader.requestAccess() }
        return false
    }

    static let note = "To click and type for you, I need the Accessibility permission. Turn on Wisp in System Settings, Privacy and Security, Accessibility, then ask again."
}
