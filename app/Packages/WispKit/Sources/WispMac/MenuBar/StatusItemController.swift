import AppKit
import Combine
import WispCore

/// Extra rows other features add to the menu (speech model status, last-turn info, …).
public struct StatusMenuSection {
    public var items: () -> [NSMenuItem]
    public init(items: @escaping () -> [NSMenuItem]) { self.items = items }
}

/// The menu bar item: shows readiness at a glance and gives access to setup, settings and quit.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let app: AppState
    private var cancellables: Set<AnyCancellable> = []

    public var onOpenSettings: (() -> Void)?
    public var onOpenOnboarding: (() -> Void)?
    public var onFixPermissions: (() -> Void)?
    /// Something besides permissions that keeps Wisp from answering (no API key, speech model not ready).
    public var setupProblem: (() -> String?)?
    /// Opens Settings on a given tab (the one that fixes the current setup problem).
    public var onOpenSettingsTab: ((String) -> Void)?
    /// Which Settings tab fixes the current setup problem.
    public var setupProblemTab: (() -> String)?
    /// Shown as "Stop Speaking" while an answer is playing.
    public var isSpeaking: (() -> Bool)?
    public var onStopSpeaking: (() -> Void)?
    public var onWhatsNew: (() -> Void)?
    /// A running timer's countdown shown next to the icon ("4:59"), or nil.
    public var countdown: String? {
        didSet {
            guard countdown != oldValue else { return }
            statusItem.length = countdown == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
            statusItem.button?.title = countdown.map { " " + $0 } ?? ""
            statusItem.button?.imagePosition = countdown == nil ? .imageOnly : .imageLeading
            statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
    }
    /// Paused until this time (nil = not paused), and the menu's pause/resume actions.
    public var pausedUntil: Date? { didSet { updateIcon() } }
    public var onPause: ((PauseState.Length) -> Void)?
    public var onResume: (() -> Void)?
    public var onReadSelection: (() -> Void)?
    public var onCheckup: (() -> Void)?
    public var onShortcuts: (() -> Void)?
    public var onHistory: (() -> Void)?
    public var onCopyScreenText: (() -> Void)?
    /// Opens the box for typing a question.
    public var onTypeQuestion: (() -> Void)?
    /// Shown as "Check for Updates…" when set (only builds with an update feed).
    public var onCheckForUpdates: (() -> Void)?
    /// Sections contributed by features, rendered between the status header and the app commands.
    public var sections: [StatusMenuSection] = []
    /// Overrides the icon while the assistant is busy (listening, thinking, speaking).
    public var activitySymbol: String? { didSet { updateIcon() } }
    /// True while the companion is out of the icon (flying or beside the pointer).
    public var companionAway = false { didSet { updateIcon() } }

    /// Centre of the menu bar icon in global coordinates (where the companion lives), or nil if hidden.
    public var anchorPoint: Vec2? {
        guard let button = statusItem.button, let window = button.window, statusItem.isVisible else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 0, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
        return Vec2(frame.midX, frame.midY)
    }

    /// A small "absorb" bounce when the companion lands back in the icon.
    public func playArrivalBounce() {
        guard let layer = statusItem.button?.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.22, 0.94, 1.0]
        bounce.keyTimes = [0, 0.35, 0.7, 1]
        bounce.duration = 0.32
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bounce, forKey: "arrive")
    }

    public init(app: AppState) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.setAccessibilityLabel("Wisp")
        statusItem.button?.wantsLayer = true
        statusItem.behavior = .removalAllowed
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        app.permissions.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let readiness = Readiness(app.permissions.snapshot)
        let symbol: String
        if let activitySymbol {
            symbol = activitySymbol
        } else if pausedUntil != nil {
            symbol = "pause.circle"
        } else if companionAway && readiness == .ready {
            // The companion has left its home: show the empty perch.
            symbol = "cursorarrow"
        } else {
            switch readiness {
            case .ready: symbol = "cursorarrow.rays"
            case .needsAttention: symbol = "exclamationmark.triangle"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wisp")
        image?.isTemplate = true
        statusItem.button?.image = image
        if let pausedUntil {
            statusItem.button?.toolTip = "Wisp is " + PauseState.description(until: pausedUntil, now: Date()).lowercased()
        } else {
            statusItem.button?.toolTip = readiness == .ready ? "Wisp: hold \(app.effectiveChord.displayName) to ask" : "Wisp needs attention"
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        app.permissions.refresh()
        menu.removeAllItems()
        let snapshot = app.permissions.snapshot

        let problem = snapshot.allGranted ? setupProblem?() : nil
        var headerText = !snapshot.allGranted ? "Wisp needs attention" : (problem == nil ? "Wisp is ready" : "Wisp is almost ready")
        if let pausedUntil { headerText = "Wisp is " + PauseState.description(until: pausedUntil, now: Date()).lowercased() }
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let problem {
            let fix = NSMenuItem(title: problem, action: #selector(openProblemTab), keyEquivalent: "")
            fix.target = self
            fix.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            menu.addItem(fix)
        }

        let hint = NSMenuItem(title: "\(app.effectiveChord.mode == .hold ? "Hold" : "Press") \(app.effectiveChord.symbols) and ask a question", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if pausedUntil != nil {
            let resume = NSMenuItem(title: "Resume Wisp", action: #selector(resume), keyEquivalent: "")
            resume.target = self
            resume.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
            menu.addItem(resume)
        }
        if onTypeQuestion != nil, snapshot.allGranted, problem == nil, pausedUntil == nil {
            let type = NSMenuItem(title: app.config.typeToAsk ? "Type a Question…  (double-tap \(app.config.typeKeyModifier.symbols))" : "Type a Question…",
                                  action: #selector(typeQuestion), keyEquivalent: "")
            type.target = self
            type.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
            menu.addItem(type)
            if onReadSelection != nil {
                let read = NSMenuItem(title: "Read Selection Aloud", action: #selector(readSelection), keyEquivalent: "")
                read.target = self
                read.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
                menu.addItem(read)
            }
            if onCopyScreenText != nil {
                let copy = NSMenuItem(title: "Copy Text on Screen", action: #selector(copyScreenText), keyEquivalent: "")
                copy.target = self
                copy.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
                menu.addItem(copy)
            }
            if onShortcuts != nil, let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier, let name = front.localizedName {
                let keys = NSMenuItem(title: "Keyboard Shortcuts in \(name)…", action: #selector(shortcuts), keyEquivalent: "")
                keys.target = self
                keys.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: nil)
                menu.addItem(keys)
            }
        }

        if isSpeaking?() == true {
            let stop = NSMenuItem(title: "Stop", action: #selector(stopSpeaking), keyEquivalent: "\u{1b}")
            stop.keyEquivalentModifierMask = []
            stop.target = self
            stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            menu.addItem(stop)
        }

        if !snapshot.allGranted {
            let fix = NSMenuItem(title: "Fix Permissions…", action: #selector(fixPermissions), keyEquivalent: "")
            fix.target = self
            fix.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(fix)
        }

        for section in sections {
            let items = section.items()
            if items.isEmpty { continue }
            menu.addItem(.separator())
            items.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        if pausedUntil == nil, onPause != nil {
            let pause = NSMenuItem(title: "Pause Wisp", action: nil, keyEquivalent: "")
            pause.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
            let sub = NSMenu()
            for length in PauseState.Length.allCases {
                let item = NSMenuItem(title: length.title, action: #selector(pauseChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = length.rawValue
                sub.addItem(item)
            }
            pause.submenu = sub
            menu.addItem(pause)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let guide = NSMenuItem(title: "Welcome Guide…", action: #selector(openOnboarding), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        if onHistory != nil {
            let history = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
            history.target = self
            menu.addItem(history)
        }
        if onCheckup != nil {
            let check = NSMenuItem(title: "Check Wisp…", action: #selector(checkup), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }
        if onWhatsNew != nil {
            let news = NSMenuItem(title: "What's New…", action: #selector(whatsNew), keyEquivalent: "")
            news.target = self
            menu.addItem(news)
        }
        if onCheckForUpdates != nil {
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openOnboarding() { onOpenOnboarding?() }
    @objc private func fixPermissions() { onFixPermissions?() }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func stopSpeaking() { onStopSpeaking?() }
    @objc private func whatsNew() { onWhatsNew?() }
    @objc private func readSelection() { onReadSelection?() }
    @objc private func checkup() { onCheckup?() }
    @objc private func shortcuts() { onShortcuts?() }
    @objc private func showHistory() { onHistory?() }
    @objc private func copyScreenText() { onCopyScreenText?() }
    @objc private func resume() { onResume?() }
    @objc private func pauseChosen(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let length = PauseState.Length(rawValue: raw) { onPause?(length) }
    }
    @objc private func typeQuestion() { onTypeQuestion?() }
    @objc private func openProblemTab() { onOpenSettingsTab?(setupProblemTab?() ?? "general") }
}

/// A menu item that runs a closure (keeps its handler alive as the item's represented object).
@MainActor
public enum MenuAction {
    public static func item(_ title: String, symbol: String? = nil, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let handler = Handler(action)
        let item = NSMenuItem(title: title, action: #selector(Handler.run), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    final class Handler: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @MainActor @objc func run() { action() }
    }
}
