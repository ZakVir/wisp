import AppKit
import SwiftUI
import WispCore

/// Shows the sentence being spoken in a small dark plate beside the pointer (click-through, never focused).
/// Two lines at most; long sentences shrink the font slightly before wrapping further. Also announced to
/// VoiceOver so screen-reader users get the answer even with speech off.
@MainActor
public final class CaptionController {
    private let panel: NSPanel
    private let model = CaptionModel()
    private var hideWork: DispatchWorkItem?
    public var enabled = true
    /// Text size multiplier (Settings: Small 0.87, Medium 1, Large 1.3).
    public var scale: CGFloat = 1 { didSet { model.scale = scale } }
    /// Centred near the bottom of the screen (like subtitles) instead of beside the pointer.
    public var atBottom = false
    /// Where the companion is pointing right now (global points), so captions never cover the target.
    public var avoidRect: (() -> CGRect?)?

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: CaptionView(model: model))
        // The window's size is set from the measured text only; SwiftUI must not resize it on its own.
        host.sizingOptions = []
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.alphaValue = 0
    }

    /// Window number, so screenshots can exclude it (they exclude the whole app anyway).
    public var windowNumber: Int { panel.windowNumber }

    /// - Parameter always: show even when captions are turned off (problems and status, which are never spoken).
    public func show(_ text: String, always: Bool = false) {
        hideWork?.cancel()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if enabled || always {
            // Size and place the plate first, then swap the text and lay out before showing, so it never
            // appears at the previous caption's size.
            let size = measure(text)
            position(size: size)
            var noAnimation = Transaction()
            noAnimation.disablesAnimations = true
            withTransaction(noAnimation) { model.text = text }
            panel.contentView?.layoutSubtreeIfNeeded()
            if panel.alphaValue < 1 || !panel.isVisible {
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = reduceMotion ? 0.1 : 0.2
                    panel.animator().alphaValue = 1
                }
            }
        }
        // VoiceOver: announce the sentence (does nothing when VoiceOver is off).
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Hides after a short hold so the last sentence can still be read.
    public func hide(after delay: TimeInterval = 1.2) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if self.panel.alphaValue < 0.01 { self.panel.orderOut(nil) } }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func measure(_ text: String) -> NSSize {
        let font = NSFont.systemFont(ofSize: CaptionView.fontSize * scale, weight: .semibold)
        let maxTextWidth: CGFloat = 440 * scale
        let rect = (text as NSString).boundingRect(with: NSSize(width: maxTextWidth, height: 400),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: font])
        return NSSize(width: ceil(min(maxTextWidth, rect.width)) + 2 * CaptionView.hPad * scale + 2,
                      height: ceil(rect.height) + 2 * CaptionView.vPad * scale + 2)
    }

    /// Below-right of the pointer; flips left/up near screen edges and moves off the pointed-at target.
    private func position(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        if atBottom {
            var frame = NSRect(x: visible.midX - size.width / 2, y: visible.minY + 48, width: size.width, height: size.height)
            // Move up if the companion is pointing at something there.
            if let avoid = avoidRect?(), frame.intersects(avoid.insetBy(dx: -8, dy: -8)) { frame.origin.y = avoid.maxY + 16 }
            panel.setFrame(frame, display: true)
            return
        }
        var origin = NSPoint(x: mouse.x + 28, y: mouse.y - 46 - size.height)
        if origin.x + size.width > visible.maxX { origin.x = mouse.x - 28 - size.width }
        if origin.y < visible.minY { origin.y = mouse.y + 40 }
        var frame = NSRect(origin: origin, size: size)
        if let avoid = avoidRect?(), frame.intersects(avoid.insetBy(dx: -8, dy: -8)) {
            // Put the caption on the other side of the target.
            frame.origin.y = avoid.minY - 16 - size.height
            if frame.minY < visible.minY { frame.origin.y = avoid.maxY + 16 }
        }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        panel.setFrame(frame, display: true)
    }
}

final class CaptionModel: ObservableObject {
    @Published var text = ""
    @Published var scale: CGFloat = 1
}

struct CaptionView: View {
    static let fontSize: CGFloat = 15
    static let hPad: CGFloat = 14
    static let vPad: CGFloat = 9
    @ObservedObject var model: CaptionModel

    var body: some View {
        Text(model.text)
            .font(.system(size: Self.fontSize * model.scale, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.hPad * model.scale)
            .padding(.vertical, Self.vPad * model.scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14 * model.scale, style: .continuous)
                    .fill(Color.black.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 14 * model.scale, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            )
            .accessibilityHidden(true) // announced separately; the panel itself is decorative
    }
}
