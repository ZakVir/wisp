import AppKit
import ApplicationServices
import WispCore

/// Finds an app on this Mac by the name someone says ("Fusion", "Chrome", "Word").
public enum AppLocator {
    public struct Found: Sendable { public var url: URL; public var name: String; public var bundleID: String? }

    private static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "word": "Microsoft Word", "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint", "teams": "Microsoft Teams", "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code", "code": "Visual Studio Code", "settings": "System Settings",
        "system preferences": "System Settings", "preferences": "System Settings", "app store": "App Store",
        "edge": "Microsoft Edge", "brave": "Brave Browser", "zoom": "zoom.us", "facetime": "FaceTime",
    ]

    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    public static func find(_ spoken: String) -> Found? {
        let wanted = aliases[spoken.lowercased()] ?? spoken
        let wantedKey = key(wanted)
        let wantedWords = Set(wanted.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !wantedKey.isEmpty else { return nil }
        var candidates: [(name: String, url: URL)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let url = app.bundleURL, let name = app.localizedName else { return nil }
            return (name, url)
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    home + "/Applications", "/System/Volumes/Preboot/Cryptexes/App/System/Applications"]
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + item
                if item.hasSuffix(".app") { candidates.append((String(item.dropLast(4)), URL(fileURLWithPath: path))) }
                else if !item.hasPrefix("."), (try? fm.contentsOfDirectory(atPath: path))?.contains(where: { $0.hasSuffix(".app") }) == true {
                    for sub in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where sub.hasSuffix(".app") {
                        candidates.append((String(sub.dropLast(4)), URL(fileURLWithPath: path + "/" + sub)))
                    }
                }
            }
        }
        func score(_ name: String) -> Int {
            let k = key(name)
            if k == wantedKey { return 4 }
            if k.hasPrefix(wantedKey) { return 3 }
            let words = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            if !wantedWords.isEmpty, wantedWords.isSubset(of: words) { return 2 }
            return 0
        }
        // Apps installed somewhere else: ask Spotlight for app bundles whose name contains the words.
        if !candidates.contains(where: { score($0.name) > 0 }) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            let words = wantedWords.map { "kMDItemDisplayName == '*\($0)*'cd" }.joined(separator: " && ")
            process.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && " + words]
            let pipe = Pipe()
            process.standardOutput = pipe
            if (try? process.run()) != nil {
                process.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                for path in out.split(separator: "\n").prefix(20) where path.hasSuffix(".app") {
                    candidates.append((String(path.split(separator: "/").last!.dropLast(4)), URL(fileURLWithPath: String(path))))
                }
            }
        }
        guard let best = candidates.map({ ($0, score($0.name)) }).filter({ $0.1 > 0 })
            .max(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name.count > $1.0.name.count }) else { return nil }
        return Found(url: best.0.url, name: best.0.name, bundleID: Bundle(url: best.0.url)?.bundleIdentifier)
    }
}

/// One menu command, chosen and carried out through Accessibility while the companion shows the clicks.
public enum MenuCommander {
    public struct Item: Sendable { public var menu: String; public var title: String; public var enabled: Bool }

    /// Every top-level menu command of the app (not the Apple menu, Help, or the Window menu's window list).
    public static func items(pid: pid_t) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = AXHelpers.element(app, kAXMenuBarAttribute) else { return [] }
        var out: [Item] = []
        for (index, top) in AXHelpers.children(bar).enumerated() where index > 0 {
            guard let menuTitle = AXHelpers.string(top, kAXTitleAttribute), !menuTitle.isEmpty, menuTitle != "Help",
                  let menu = AXHelpers.children(top).first else { continue }
            for item in AXHelpers.children(menu) {
                guard let title = AXHelpers.string(item, kAXTitleAttribute), !title.isEmpty, title != "Services" else { continue }
                out.append(Item(menu: menuTitle, title: title, enabled: (AXHelpers.attribute(item, kAXEnabledAttribute) as? Bool) ?? true))
            }
        }
        return out
    }

    /// Commands Wisp never chooses for anyone: they delete, send, pay or end things.
    public static func isSafe(_ item: Item) -> Bool {
        let t = item.title.lowercased()
        let unsafe = ["delete", "erase", "trash", "remove", "send", "buy", "purchase", "pay", "sign out", "log out", "restart",
                      "shut down", "quit", "revert", "discard", "format", "reset", "uninstall", "empty", "force"]
        return !unsafe.contains { t.contains($0) }
    }

    /// A command all of whose words are in the request ("make a new document" → New; "open a new tab" → New Tab),
    /// the most specific (longest) first.
    public static func chooseLocally(_ task: String, from items: [Item]) -> Item? {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let taskWords = words(task)
        return items.filter { item in
            let w = words(item.title)
            return !w.isEmpty && w.isSubset(of: taskWords) && isSafe(item) && !(w.count == 1 && ["open", "close", "save", "print", "find"].contains(w.first!))
        }.max { a, b in words(a.title).count != words(b.title).count ? words(a.title).count < words(b.title).count : a.title.count < b.title.count }
    }

    /// Clicks `item`'s menu title, then the item, with the companion pointing at each just as it happens.
    @MainActor
    public static func perform(_ item: Item, pid: pid_t, overlay: OverlayController?) async -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = AXHelpers.element(app, kAXMenuBarAttribute),
              let top = AXHelpers.children(bar).first(where: { AXHelpers.string($0, kAXTitleAttribute) == item.menu }) else { return false }
        if let overlay, let f = AXHelpers.frame(top) { _ = await overlay.pointAndClick(at: AXHelpers.appKitCenter(f), label: item.menu) }
        AXUIElementPerformAction(top, kAXPressAction as CFString) // the menu opens as the cursor clicks
        try? await Task.sleep(for: .milliseconds(350))
        guard let menu = AXHelpers.children(top).first,
              let element = AXHelpers.children(menu).first(where: { AXHelpers.string($0, kAXTitleAttribute) == item.title }) else {
            AXUIElementPerformAction(top, kAXCancelAction as CFString)
            return false
        }
        if let overlay, let f = AXHelpers.frame(element), f.width > 0 { _ = await overlay.pointAndClick(at: AXHelpers.appKitCenter(f), label: item.title) }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}

/// Opens an app (clicking it in the Dock as it opens) and does at most one menu command in it.
@MainActor
public final class AppActor {
    private let overlay: OverlayController?
    /// Picks the menu command for a request with the AI (the request, the app's commands as "Menu > Item", the app).
    public var chooseWithAI: ((String, [String], String) async -> String?)?

    public init(overlay: OverlayController?) { self.overlay = overlay }

    private static func openDirectly(_ found: AppLocator.Found) async {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: found.url, configuration: config)
    }

    public func run(_ action: AppAction) async -> String {
        var pid: pid_t
        var name: String
        if let spoken = action.app {
            guard let found = AppLocator.find(spoken) else { return "I couldn't find an app called \(spoken) on this Mac." }
            name = found.name
            let running = found.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            var permissionNote = ""
            if running?.isActive != true {
                if !ComputerUsePermission.check() {
                    // Without Accessibility it can't see the Dock or click for real: open it plainly and say why.
                    await Self.openDirectly(found)
                    permissionNote = " " + ComputerUsePermission.note
                } else if await DockDriver.click(found, overlay: overlay) {
                    // Clicked in the Dock: it opens as the companion clicks.
                } else if await AppLauncher.open(found, overlay: overlay) {
                    // Found in the Apps launcher, opened from its results.
                } else {
                    AppLauncher.close()
                    await Self.openDirectly(found)
                }
                // Make sure it really came up; if the launcher opened something else, close it and open the app.
                if let id = found.bundleID, await WebActor.waitForFront(bundleID: id, timeout: 4) == nil {
                    AppLauncher.close()
                    await Self.openDirectly(found)
                }
            }
            if !permissionNote.isEmpty { return "\(name) is open." + permissionNote }
            guard let id = found.bundleID, let front = await WebActor.waitForFront(bundleID: id) else {
                return action.task == nil ? "\(name) is opening." : "\(name) is taking a while to open. Try again in a moment."
            }
            pid = front
        } else {
            guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return "Click the app you want first, then ask again."
            }
            pid = front.processIdentifier
            name = front.localizedName ?? "this app"
        }
        guard let task = action.task else { return "\(name) is open." }
        if AppAction.isTooBig(task) {
            return "I opened \(name). The rest is more than I do for you, but ask me how and I'll walk you through it."
        }
        guard ComputerUsePermission.check() else { return "I opened \(name). " + ComputerUsePermission.note }
        // A freshly opened app needs a moment for its menus.
        var items = MenuCommander.items(pid: pid)
        for _ in 0..<20 where items.count < 4 {
            try? await Task.sleep(for: .milliseconds(150))
            items = MenuCommander.items(pid: pid)
        }
        var choice = MenuCommander.chooseLocally(task, from: items)
        if choice == nil, let ai = chooseWithAI {
            let list = items.map { "\($0.menu) > \($0.title)" }
            if let answer = await ai(task, list, name) {
                let a = answer.lowercased()
                choice = items.first { "\($0.menu) > \($0.title)".lowercased() == a }
                    ?? items.first { a.contains($0.title.lowercased()) && a.contains($0.menu.lowercased()) }
            }
        }
        guard let item = choice else {
            return "\(name) is open, but I couldn't find one menu command that does that. Ask me how and I'll show you."
        }
        guard MenuCommander.isSafe(item) else { return "I won't do \(item.title) for you, but ask me how and I'll show you where it is." }
        guard item.enabled else { return "\(item.menu) > \(item.title) is greyed out in \(name) right now." }
        let ok = await MenuCommander.perform(item, pid: pid, overlay: overlay)
        return ok ? "Done: \(item.menu), \(item.title)." : "I couldn't open \(item.menu), \(item.title) just now."
    }
}

/// Small Accessibility helpers for the actors.
enum AXHelpers {
    static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }
    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func children(_ e: AXUIElement) -> [AXUIElement] {
        guard let v = attribute(e, kAXChildrenAttribute), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
    /// Top-left-based global frame.
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
    @MainActor
    static func appKitCenter(_ f: CGRect) -> Vec2 {
        Vec2(f.midX, Double(NSScreen.screens.first?.frame.height ?? 0) - f.midY)
    }
}
