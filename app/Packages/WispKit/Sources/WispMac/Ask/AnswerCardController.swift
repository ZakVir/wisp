import AppKit
import SwiftUI
import WispCore

/// The full answer to a typed question, in a card where the question box was: easy to read in a meeting, with
/// Copy. Doesn't take focus; closes on its own after a while, with Escape (via Wisp), or with its close button.
@MainActor
public final class AnswerCardController {
    private var panel: NSPanel?
    private let model = AnswerCardModel()
    private var hideTask: Task<Void, Never>?
    /// Says the shown answer again (the card's Say Again button).
    public var onSayAgain: ((String) -> Void)?

    public init() {}

    public var isVisible: Bool { panel?.isVisible == true }

    public func show(question: String, answer: String, near frame: NSRect?) {
        model.question = question
        model.answer = answer
        model.copied = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = panel.contentView as? NSHostingView<AnswerCardView>
        let size = host?.fittingSize ?? NSSize(width: AnswerCardView.width, height: 120)
        panel.setContentSize(size)
        position(panel, below: frame)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        scheduleHide(after: max(12, Double(answer.count) / 12)) // about reading speed, at least 12 s
    }

    public func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.model.hovering else { return }
            self.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: AnswerCardView.width, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = AnswerCardView(model: model, onCopy: { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.model.answer, forType: .string)
            self.model.copied = true
        }, onSayAgain: { [weak self] in
            guard let self else { return }
            self.onSayAgain?(self.model.answer)
        }, onClose: { [weak self] in self?.hide() }, onHoverEnd: { [weak self] in self?.scheduleHide(after: 6) })
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        return panel
    }

    /// Under the question box's spot (or a third of the way down the pointer's display).
    private func position(_ panel: NSPanel, below frame: NSRect?) {
        let size = panel.frame.size
        if let frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY - 10 - size.height))
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.maxY - v.height * 0.28 - 40 - size.height))
    }
}

@MainActor
final class AnswerCardModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var copied = false
    var hovering = false
}

struct AnswerCardView: View {
    static let width: CGFloat = 600
    @ObservedObject var model: AnswerCardModel
    var onCopy: () -> Void
    var onSayAgain: () -> Void
    var onClose: () -> Void
    var onHoverEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Text(model.answer)
                .font(.system(size: 15))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Say Again", action: onSayAgain)
                    .controlSize(.small)
                Button(model.copied ? "Copied" : "Copy", action: onCopy)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(2)
        .onHover { inside in
            model.hovering = inside
            if !inside { onHoverEnd() }
        }
    }
}
