import AppKit
import SwiftUI
import WispCore

/// The front app's keyboard shortcuts in a floating card, grouped by menu, with a filter field. Read from the
/// app's menus through macOS (no AI). Doesn't switch apps; closes with Escape or its close button.
@MainActor
public final class ShortcutsCardController {
    private var panel: AskPanel?
    private let model = ShortcutsModel()

    public init() {}

    public var isVisible: Bool { panel?.isVisible == true }

    public func show(appName: String, icon: NSImage?, items: [UIContext.MenuItem]) {
        model.appName = appName
        model.icon = icon
        model.items = items
        model.filter = ""
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        model.focusToken += 1
    }

    public func hide() { panel?.orderOut(nil) }

    private func makePanel() -> AskPanel {
        let size = NSSize(width: ShortcutsCardView.size.width + 4, height: ShortcutsCardView.size.height + 4)
        let panel = AskPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onResign = { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(rootView: ShortcutsCardView(model: model, onClose: { [weak self] in self?.hide() }))
        return panel
    }
}

@MainActor
final class ShortcutsModel: ObservableObject {
    @Published var appName = ""
    @Published var icon: NSImage?
    @Published var items: [UIContext.MenuItem] = []
    @Published var filter = ""
    @Published var focusToken = 0

    /// Menus in their order, each with its (filtered) commands.
    var groups: [(menu: String, items: [UIContext.MenuItem])] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [(String, [UIContext.MenuItem])] = []
        for item in items where f.isEmpty || item.title.lowercased().contains(f) || item.menu.lowercased().contains(f) {
            if let i = out.firstIndex(where: { $0.0 == item.menu }) { out[i].1.append(item) } else { out.append((item.menu, [item])) }
        }
        return out.map { (menu: $0.0, items: $0.1) }
    }
}

struct ShortcutsCardView: View {
    static let size = CGSize(width: 640, height: 560)
    @ObservedObject var model: ShortcutsModel
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                }
                Text("Keyboard shortcuts in \(model.appName)").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            TextField("Filter", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onExitCommand(perform: onClose)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groups, id: \.menu) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.menu.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(item.title).foregroundStyle(item.enabled ? .primary : .secondary)
                                    Spacer()
                                    Text(item.shortcut ?? "")
                                        .font(.system(size: 13, weight: .medium).monospaced())
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(WispStyle.groupedRow, in: RoundedRectangle(cornerRadius: 5))
                                }
                                .font(.system(size: 13))
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    if model.groups.isEmpty {
                        Text(model.items.isEmpty ? "This app doesn't list any keyboard shortcuts in its menus." : "No shortcut matches.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(2)
        .tint(WispStyle.accent)
        .onChange(of: model.focusToken) { focused = true }
    }
}
