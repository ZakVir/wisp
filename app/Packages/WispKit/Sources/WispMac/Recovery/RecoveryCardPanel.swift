import AppKit
import SwiftUI
import WispCore

/// A small floating card that explains a missing or revoked permission and offers the one action that
/// fixes it. Appears near the top of the display the user is working on; dismisses itself once fixed.
@MainActor
public final class RecoveryCardController {
    private var panel: NSPanel?
    private let app: AppState
    private var observation: Task<Void, Never>?
    private var shownKind: PermissionKind?
    private var hideGeneration = 0

    public init(app: AppState) {
        self.app = app
    }

    public var isVisible: Bool { panel?.isVisible == true }

    /// Shows a card for the first unusable permission in `kinds` (or the snapshot's first missing one).
    public func show(for kinds: [PermissionKind]? = nil) {
        let snapshot = app.permissions.refresh()
        let candidates = kinds ?? snapshot.missing
        guard let kind = candidates.first(where: { !snapshot[$0].isUsable }) else {
            hide()
            return
        }
        shownKind = kind
        let view = RecoveryCardView(app: app, kind: kind, onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        hideGeneration += 1 // cancels a pending fade-out
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        // Always animate to fully visible: this also overrides a fade-out that is still in flight.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        app.permissions.startPolling(owner: "recovery")
        watchForFix()
        NSAccessibility.post(element: hosting, notification: .announcementRequested,
                             userInfo: [.announcement: "Wisp needs \(kind.settingsPaneName) access.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    public func hide() {
        observation?.cancel()
        observation = nil
        shownKind = nil
        app.permissions.stopPolling(owner: "recovery")
        guard let panel, panel.isVisible else { return }
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() during the fade wins: don't order out a panel that is being re-shown.
                guard let self, self.hideGeneration == generation, self.shownKind == nil else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func watchForFix() {
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            guard let self else { return }
            for await snapshot in self.app.permissions.$snapshot.values {
                guard let kind = self.shownKind else { return }
                if snapshot[kind].isUsable {
                    // Move on to the next missing permission, or close when everything works.
                    if snapshot.allGranted { self.hide() } else { self.show() }
                    return
                }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: .zero,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }
}

struct RecoveryCardView: View {
    @ObservedObject var app: AppState
    var kind: PermissionKind
    var onClose: () -> Void

    var body: some View {
        let state = app.permissions.snapshot[kind]
        let card = RecoveryCard.make(kind: kind, state: state, chord: app.effectiveChord,
                                     wasPreviouslyGranted: app.permissions.wasEverGranted(kind))
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [WispStyle.accent, WispStyle.accentSecondary],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(card?.title ?? "All set")
                    .font(.headline)
                Text(card?.message ?? "\(kind.settingsPaneName) is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Not Now", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    PermissionActionButtons(app: app, kind: kind, state: state)
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }

    private var symbol: String {
        switch kind {
        case .microphone: "mic.slash"
        case .inputMonitoring: "keyboard"
        case .screenRecording: "eye.slash"
        }
    }
}

/// Borderless panels cannot become key by default, which would block Esc, Tab and VoiceOver focus.
/// It still never activates the app (non-activating style).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
