import AppKit
import Combine
import SwiftUI
import WispCore

/// Something the question box can do besides asking (read aloud, copy text on screen, …), offered as you type.
public struct QuickAction: Identifiable {
    public enum Kind {
        /// Closes the box, then runs.
        case run(() -> Void)
        /// Asks this question (as if typed).
        case ask(String)
        /// Puts this text in the box to finish typing ("Set a timer for ").
        case fill(String)
    }

    public var id: String
    public var title: String
    public var symbol: String
    public var keywords: [String]
    public var kind: Kind

    public init(id: String, title: String, symbol: String, keywords: [String] = [], kind: Kind) {
        self.id = id; self.title = title; self.symbol = symbol; self.keywords = keywords; self.kind = kind
    }

    /// Shown for `text`: everything when empty (the first few), otherwise when every typed word starts a word of
    /// the title or keywords.
    func matches(_ text: String) -> Bool {
        let typed = text.lowercased().split(separator: " ").map(String.init)
        guard !typed.isEmpty else { return true }
        let words = (title + " " + keywords.joined(separator: " ")).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return typed.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
    }
}

/// A small floating box for typing a question (double-tap a key, or the menu). It takes keystrokes without
/// switching apps away from the one being asked about, and closes on Return (asks), Escape or clicking away.
/// Matching quick actions appear under it (arrow keys and Return pick one).
@MainActor
public final class AskBoxController {
    private var panel: AskPanel?
    private let model = AskBoxModel()
    private var cancellables: Set<AnyCancellable> = []
    /// Called with the question when the user presses Return.
    public var onAsk: ((String) -> Void)?
    /// Command-Return: ask without sound (captions and the card only).
    public var onAskSilently: ((String) -> Void)?
    /// Called when the box closes without asking.
    public var onCancel: (() -> Void)?
    /// The quick actions available right now (built when the box opens).
    public var actions: (() -> [QuickAction])?

    public init() {
        model.$text.combineLatest(model.$all)
            .map { text, all in Array(all.filter { $0.matches(text) }.prefix(text.isEmpty ? 4 : 5)) }
            .sink { [weak self] list in
                guard let self else { return }
                self.model.suggestions = list
                self.model.highlight = nil
                self.resize()
            }
            .store(in: &cancellables)
    }

    public var isVisible: Bool { panel?.isVisible == true }
    /// Where the box was last shown (for the answer card).
    public var lastFrame: NSRect? { panel?.frame }

    private static let recentKey = "wisp.quickActions.recent"

    public func show(hint: String) {
        // The ones used recently come first (the order only matters before typing; typing filters).
        let recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        let all = actions?() ?? []
        model.all = all.sorted { a, b in
            let ia = recent.firstIndex(of: a.id) ?? Int.max, ib = recent.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
        model.text = ""
        model.hint = hint
        let panel = self.panel ?? makePanel()
        self.panel = panel
        resize()
        position(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
        model.focusToken += 1
    }

    /// Puts text in the box (debug review of the suggestions).
    public func setText(_ text: String) {
        model.text = text
        model.focusToken += 1
    }

    /// Closes the box; `asked` decides whether `onCancel` runs.
    public func close(asked: Bool = false) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        if !asked { onCancel?() }
    }

    private func submitSilently() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        close(asked: true)
        (onAskSilently ?? onAsk)?(text)
    }

    private func submit() {
        if let index = model.highlight, model.suggestions.indices.contains(index) {
            activate(model.suggestions[index])
            return
        }
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        close(asked: true)
        onAsk?(text)
    }

    private func activate(_ action: QuickAction) {
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        recent.removeAll { $0 == action.id }
        recent.insert(action.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(8)), forKey: Self.recentKey)
        switch action.kind {
        case .run(let run):
            close()
            run()
        case .ask(let question):
            close(asked: true)
            onAsk?(question)
        case .fill(let text):
            model.text = text
            model.focusToken += 1
        }
    }

    private func makePanel() -> AskPanel {
        let panel = AskPanel(contentRect: NSRect(x: 0, y: 0, width: AskBoxView.width + 4, height: 64),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onResign = { [weak self] in self?.close() }
        let view = AskBoxView(model: model, onSubmit: { [weak self] in self?.submit() },
                              onSubmitSilently: { [weak self] in self?.submitSilently() },
                              onCancel: { [weak self] in self?.close() },
                              onPick: { [weak self] action in self?.activate(action) })
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    /// Grows downwards with the suggestions; the box itself stays where it is.
    private func resize() {
        guard let panel else { return }
        let rows = model.suggestions.count
        let height = 64 + (rows > 0 ? CGFloat(rows) * AskBoxView.rowHeight + 14 : 0)
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: AskBoxView.width + 4, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }

    /// Centred on the display with the pointer, a third of the way down (where Spotlight sits).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let top = v.maxY - v.height * 0.28 + 32
        panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2, y: top - panel.frame.height))
    }
}

/// Can become key without activating Wisp, so the app being asked about stays in front.
final class AskPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
    override func cancelOperation(_ sender: Any?) { onResign?() }
}

@MainActor
final class AskBoxModel: ObservableObject {
    @Published var text = ""
    @Published var hint = ""
    @Published var focusToken = 0
    @Published var all: [QuickAction] = []
    @Published var suggestions: [QuickAction] = []
    @Published var highlight: Int?
}

struct AskBoxView: View {
    static let width: CGFloat = 600
    static let rowHeight: CGFloat = 36
    @ObservedObject var model: AskBoxModel
    var onSubmit: () -> Void
    var onSubmitSilently: () -> Void
    var onCancel: () -> Void
    var onPick: (QuickAction) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [WispStyle.accent, WispStyle.accentSecondary],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityHidden(true)
                TextField("Ask Wisp about your screen…", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: onCancel)
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        onSubmitSilently()
                        return .handled
                    }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.tab) {
                        guard !model.suggestions.isEmpty else { return .ignored }
                        onPick(model.suggestions[min(model.highlight ?? 0, model.suggestions.count - 1)])
                        return .handled
                    }
                    .accessibilityLabel("Question for Wisp")
                Text(model.highlight != nil ? "return to run  ·  esc to close"
                     : model.suggestions.isEmpty ? model.hint : "↓ actions  ·  return to ask  ·  ⌘ return: silent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 18)
            .frame(height: 60)
            if !model.suggestions.isEmpty {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, action in
                        Button { onPick(action) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.symbol)
                                    .frame(width: 20)
                                    .foregroundStyle(model.highlight == index ? .white : WispStyle.accent)
                                Text(action.title)
                                    .foregroundStyle(model.highlight == index ? .white : .primary)
                                Spacer()
                                if model.highlight == index {
                                    Text("↩").foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .font(.system(size: 14))
                            .padding(.horizontal, 12)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(model.highlight == index ? WispStyle.accent : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(2)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: model.focusToken) {
            // Re-focusing makes the field show text set from code (a filled-in action) with the caret at its end.
            focused = false
            DispatchQueue.main.async {
                focused = true
                // Focusing selects everything; put the caret at the end so typing continues the text.
                DispatchQueue.main.async {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    }
                }
            }
        }
        .onAppear { focused = true }
    }

    private func move(_ step: Int) {
        guard !model.suggestions.isEmpty else { return }
        let count = model.suggestions.count
        if let h = model.highlight {
            let next = h + step
            model.highlight = next < 0 ? nil : min(count - 1, next)
        } else if step > 0 {
            model.highlight = 0
        }
    }
}
