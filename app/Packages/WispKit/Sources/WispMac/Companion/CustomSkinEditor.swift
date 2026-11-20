import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WispCore

/// The theme gallery: built-in themes plus the user's own skin. Used by Settings > Companion and setup.
struct ThemeGallery: View {
    @ObservedObject var app: AppState
    var tileMinimum: CGFloat = 92
    @State private var editing = false

    var body: some View {
        let overlay = app.config.overlay
        let selectedID = overlay.cursorThemeID
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum, maximum: tileMinimum + 28), spacing: 12)], spacing: 12) {
            ForEach(ThemeCatalog.all) { candidate in
                ThemeTile(theme: candidate, outline: overlay.outline, selected: candidate.id == selectedID) {
                    app.update { $0.overlay.cursorThemeID = candidate.id }
                }
            }
            if let skin = overlay.customSkin {
                let selected = selectedID == ThemeCatalog.customID
                VStack(spacing: 2) {
                    ThemeTile(theme: skin.theme, outline: overlay.outline, selected: selected) {
                        if selected { editing = true } else { app.update { $0.overlay.cursorThemeID = ThemeCatalog.customID } }
                    }
                    Button("Edit…") { editing = true }.buttonStyle(.link).font(.caption)
                }
            } else {
                Button { editing = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        Text("Your own…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Make your own skin")
            }
        }
        .disabled(app.isLocked("overlay.cursorThemeID"))
        .sheet(isPresented: $editing) {
            CustomSkinEditor(app: app, skin: overlay.customSkin ?? .starter) { editing = false }
        }
    }
}

/// Make a skin: one colour, a gradient, or the colours of a photo, with a live preview.
struct CustomSkinEditor: View {
    @ObservedObject var app: AppState
    @State var skin: CustomSkin
    var close: () -> Void
    @State private var photoMessage: String?
    @State private var photoName: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Your own skin").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 10) {
                    CompanionPreview(theme: skin.theme, outline: app.config.overlay.outline)
                        .frame(width: 140, height: 140)
                        .frame(width: 180, height: 180)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                        .accessibilityLabel("Preview of your skin")
                    HStack(spacing: 6) {
                        swatch(skin.theme.accent)
                        swatch(skin.theme.accentSecondary)
                        Text("App colours").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Kind", selection: $skin.kind) {
                        Text("Solid").tag(CustomSkin.Kind.solid)
                        Text("Gradient").tag(CustomSkin.Kind.gradient)
                        Text("From a photo").tag(CustomSkin.Kind.photo)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: skin.kind) { _, kind in
                        if kind == .solid, skin.colors.count > 1 { skin.colors = [skin.colors.max { $0.saturation < $1.saturation }!] }
                        if kind != .solid, skin.colors.count < 2 { skin.colors.append((skin.colors.first ?? RGB(hex: 0x3B1FD1)).mixed(with: RGB(1, 1, 1), 0.45)) }
                    }

                    switch skin.kind {
                    case .solid:
                        ColorPicker("Colour", selection: colorBinding(0), supportsOpacity: false)
                        Text("One colour, gently shaded so the companion still looks alive.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    case .gradient:
                        stops
                    case .photo:
                        HStack {
                            Button("Choose Photo…", action: choosePhoto)
                            if let photoName { Text(photoName).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                        Text("Wisp picks the photo's main colours (up to 50 MB; HEIC, JPEG, PNG…). Only the colours are kept, not the photo.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let photoMessage { Text(photoMessage).font(.callout).foregroundStyle(.orange) }
                        if skin.colors.count > 1 { stops }
                    }

                    if skin.kind != .solid {
                        Picker("Movement", selection: $skin.style) {
                            Text("Flowing bands").tag(FluidStyle.bands)
                            Text("Soft blobs").tag(FluidStyle.blobs)
                            Text("Light rays").tag(FluidStyle.rays)
                        }
                    }
                }
                .frame(width: 300, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Use This Skin") {
                    app.update {
                        $0.overlay.customSkin = skin
                        $0.overlay.cursorThemeID = ThemeCatalog.customID
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(skin.colors.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var stops: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(skin.colors.indices, id: \.self) { i in
                HStack {
                    ColorPicker("Colour \(i + 1)", selection: colorBinding(i), supportsOpacity: false)
                    Spacer()
                    Button { skin.colors.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(skin.colors.count <= 2)
                        .accessibilityLabel("Remove colour \(i + 1)")
                }
            }
            Button {
                skin.colors.append(skin.colors.last?.mixed(with: RGB(1, 1, 1), 0.4) ?? RGB(1, 1, 1))
            } label: { Label("Add Colour", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
                .disabled(skin.colors.count >= CustomSkin.maxColors)
        }
    }

    private func colorBinding(_ i: Int) -> Binding<Color> {
        Binding(get: {
            guard skin.colors.indices.contains(i) else { return .white }
            let c = skin.colors[i]
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
        }, set: { color in
            guard skin.colors.indices.contains(i), let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            skin.colors[i] = RGB(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        })
    }

    private func swatch(_ c: RGB) -> some View {
        Circle().fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b)).frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3)))
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo. Wisp uses its colours for your companion."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let colors = try PaletteExtractor.colors(from: url)
            guard colors.count >= 2 else { photoMessage = "That photo is nearly one colour. Try Solid instead, or another photo."; return }
            skin.colors = colors
            photoName = url.lastPathComponent
            photoMessage = nil
        } catch {
            photoMessage = (error as? PaletteExtractor.Failure)?.message ?? PaletteExtractor.Failure.unreadable.message
        }
    }
}
