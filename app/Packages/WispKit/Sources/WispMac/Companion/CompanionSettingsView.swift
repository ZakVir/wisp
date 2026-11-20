import AppKit
import QuartzCore
import SwiftUI
import WispCore

/// A live, animated companion rendered with the same Metal renderer as the overlay.
struct CompanionPreview: NSViewRepresentable {
    var theme: CompanionTheme
    var outline: CompanionOutline = .white
    var morph: Double = 0
    var opacity: Double = 1
    var animated = true

    func makeNSView(context: Context) -> CompanionPreviewNSView {
        let view = CompanionPreviewNSView()
        view.configure(theme: theme, outline: outline, morph: morph, opacity: opacity, animated: animated)
        return view
    }

    func updateNSView(_ view: CompanionPreviewNSView, context: Context) {
        view.configure(theme: theme, outline: outline, morph: morph, opacity: opacity, animated: animated)
    }

    static func dismantleNSView(_ view: CompanionPreviewNSView, coordinator: ()) {
        view.stop()
    }
}

final class CompanionPreviewNSView: NSView {
    private let metalLayer = CompanionMetalLayer()
    private var link: CADisplayLink?
    private var theme = ThemeCatalog.theme(id: ThemeCatalog.defaultID)
    private var outline: CompanionOutline = .white
    private var targetMorph = 0.0
    private var morph = 0.0
    private var opacityValue = 1.0
    private var animated = true
    /// Accumulated pattern time, so toggling animation never makes the pattern jump.
    private var phase: Double = 3
    private var lastTick: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(metalLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(theme: CompanionTheme, outline: CompanionOutline, morph: Double, opacity: Double, animated: Bool) {
        self.theme = theme
        self.outline = outline
        targetMorph = morph
        opacityValue = opacity
        self.animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updateLink()
        draw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { updateBacking(); updateLink(); draw() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBacking()
        draw()
    }

    override func layout() {
        super.layout()
        updateBacking()
        draw()
    }

    private func updateBacking() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        metalLayer.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        metalLayer.updateDrawableSize()
        CATransaction.commit()
    }

    /// A display link runs only while something moves (animated tile, or the arrow↔hand morph).
    private func updateLink() {
        let needsLink = window != nil && (animated || abs(targetMorph - morph) > 0.001 || !CompanionRenderer.shared.isReady)
        if needsLink, link == nil {
            let link = displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = 0
        } else if !needsLink {
            stop()
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTick == 0 ? 1.0 / 60.0 : min(0.1, now - lastTick)
        lastTick = now
        if animated { phase += dt }
        morph += (targetMorph - morph) * min(1, dt * 10)
        if abs(targetMorph - morph) < 0.001 { morph = targetMorph }
        draw()
        updateLink()
    }

    private func draw() {
        var uniforms = CompanionUniforms(time: phase, morph: morph, opacity: opacityValue)
        uniforms.outline = outline
        CompanionRenderer.shared.draw(into: metalLayer, uniforms: uniforms, theme: theme)
    }
}

/// Settings > Companion: theme gallery, live preview, keep-on-screen, size and transparency.
struct CompanionSettingsView: View {
    @ObservedObject var app: AppState
    /// Live values while a slider is being dragged (saved to settings on release).
    @State private var draftScale: Double?
    @State private var draftOpacity: Double?

    var body: some View {
        var overlay = app.config.overlay.sanitized
        let _ = { if let d = draftScale { overlay.cursorScale = d }; if let d = draftOpacity { overlay.idleOpacity = d } }()
        let theme = overlay.resolvedTheme
        Form {
            Section {
                HStack(spacing: 20) {
                    CompanionPreview(theme: theme, outline: overlay.outline, opacity: overlay.keepOnScreen ? overlay.idleOpacity : 1)
                        .frame(width: 130 * min(1.4, overlay.cursorScale), height: 130 * min(1.4, overlay.cursorScale))
                        .frame(width: 180, height: 180)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                        .accessibilityLabel("Preview of the \(theme.name) companion")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(theme.name).font(.title3.weight(.semibold))
                        Text(overlay.keepOnScreen
                             ? "Your companion waits beside your pointer and flies to things on screen when you ask a question."
                             : "Your companion flies out of the menu bar when you ask a question and points at things on screen.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                    }
                }
            }

            Section("Theme") {
                ThemeGallery(app: app)
                    .padding(.vertical, 4)
            }

            Section("Look") {
                Picker("Outline", selection: Binding(
                    get: { overlay.outline },
                    set: { v in app.update { $0.overlay.outline = v } })) {
                    Text("White").tag(CompanionOutline.white)
                    Text("Black").tag(CompanionOutline.black)
                    Text("None").tag(CompanionOutline.none)
                }
                .pickerStyle(.segmented)
                .disabled(app.isLocked("overlay.outline"))
            }

            Section("Behaviour") {
                Toggle("Keep the companion on screen", isOn: Binding(
                    get: { overlay.keepOnScreen },
                    set: { v in app.update { $0.overlay.keepOnScreen = v } }))
                    .disabled(app.isLocked("overlay.keepOnScreen"))
                Text(overlay.keepOnScreen
                     ? "The companion stays beside your pointer all the time."
                     : "The companion lives in the menu bar and flies out only while you ask a question.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Size") {
                    Slider(value: Binding(get: { draftScale ?? overlay.cursorScale }, set: { draftScale = $0 }),
                           in: OverlaySettings.scaleRange) {
                        Text("Size")
                    } minimumValueLabel: {
                        Image(systemName: "cursorarrow").imageScale(.small)
                    } maximumValueLabel: {
                        Image(systemName: "cursorarrow").imageScale(.large)
                    } onEditingChanged: { editing in
                        if !editing, let value = draftScale {
                            app.update { $0.overlay.cursorScale = value }
                            draftScale = nil
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Companion size")
                }
                .disabled(app.isLocked("overlay.cursorScale"))
                LabeledContent("Transparency when idle") {
                    Slider(value: Binding(get: { draftOpacity ?? overlay.idleOpacity }, set: { draftOpacity = $0 }),
                           in: OverlaySettings.idleOpacityRange) {
                        Text("Opacity")
                    } minimumValueLabel: {
                        Image(systemName: "circle.dotted").imageScale(.small)
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill").imageScale(.small)
                    } onEditingChanged: { editing in
                        if !editing, let value = draftOpacity {
                            app.update { $0.overlay.idleOpacity = value }
                            draftOpacity = nil
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Transparency when idle")
                }
                .disabled(!overlay.keepOnScreen || app.isLocked("overlay.idleOpacity"))
                .help(overlay.keepOnScreen ? "How see-through the companion is while it waits beside your pointer." : "")
                if !overlay.keepOnScreen {
                    Text("Turn on “Keep the companion on screen” to change this.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Reduce motion", selection: Binding(
                    get: { overlay.reduceMotion },
                    set: { v in app.update { $0.overlay.reduceMotion = v } })) {
                    Text("Follow System Settings").tag(ReduceMotionPreference.system)
                    Text("Always").tag(ReduceMotionPreference.on)
                    Text("Never").tag(ReduceMotionPreference.off)
                }
                .disabled(app.isLocked("overlay.reduceMotion"))
            }
        }
        .formStyle(.grouped)
    }
}

/// One theme in the gallery: live animated arrow plus its name; selected theme gets an accent ring.
struct ThemeTile: View {
    var theme: CompanionTheme
    var outline: CompanionOutline
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                CompanionPreview(theme: theme, outline: outline, animated: hovering || selected)
                    .frame(width: 64, height: 64)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? accent : Color.secondary.opacity(hovering ? 0.35 : 0.15), lineWidth: selected ? 2 : 1))
                Text(theme.name)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .animation(.snappy(duration: 0.15), value: hovering)
    }

    private var accent: Color {
        Color(.sRGB, red: theme.accent.r, green: theme.accent.g, blue: theme.accent.b)
    }
}
