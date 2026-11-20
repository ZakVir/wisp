import AppKit
import SwiftUI
import WispCore

/// "A closer look": the area around the pointer, enlarged 2.5× in a floating panel. Click-through to close;
/// fades after a while or with Escape.
@MainActor
public final class MagnifierController {
    public static let area = CGSize(width: 360, height: 220) // points around the pointer
    public static let zoom: CGFloat = 2.5
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    public init() {}

    public var isVisible: Bool { panel?.isVisible == true }

    /// Captures and shows the area around `point` (AppKit global). Returns false if the screen couldn't be read.
    public func show(around point: NSPoint, privateApps: Set<String>) async -> Bool {
        let capturer = ScreenCapturer()
        capturer.longEdge = 5120
        capturer.letSystemScale = false
        capturer.showsCursor = false
        capturer.hiddenBundleIDs = privateApps
        guard let shot = try? await capturer.captureDisplay(under: point) else { return false }
        let r = shot.record
        let frame = NSRect(x: point.x - Self.area.width / 2, y: point.y - Self.area.height / 2,
                           width: Self.area.width, height: Self.area.height)
        let a = r.imagePoint(fromGlobal: Vec2(frame.minX, frame.maxY)), b = r.imagePoint(fromGlobal: Vec2(frame.maxX, frame.minY))
        let crop = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)).integral
        guard !crop.isEmpty, let cg = shot.image.cropping(to: crop) else { return false }
        let image = NSImage(cgImage: cg, size: NSSize(width: crop.width / r.pointPixelScale, height: crop.height / r.pointPixelScale))
        present(image, near: point)
        return true
    }

    public func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    private func present(_ image: NSImage, near point: NSPoint) {
        let size = NSSize(width: image.size.width * Self.zoom, height: image.size.height * Self.zoom + 30)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: MagnifierView(image: image, size: size, onClose: { [weak self] in self?.hide() }))
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, v.minX), v.maxX - size.width)
        origin.y = min(max(origin.y, v.minY), v.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct MagnifierView: View {
    let image: NSImage
    let size: NSSize
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height - 30)
                .accessibilityLabel("Enlarged view of the area around the pointer")
            HStack {
                Label("Closer look", systemImage: "plus.magnifyingglass").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("Click or press Escape to close").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WispStyle.accent.opacity(0.6), lineWidth: 2))
        .onTapGesture(perform: onClose)
    }
}
