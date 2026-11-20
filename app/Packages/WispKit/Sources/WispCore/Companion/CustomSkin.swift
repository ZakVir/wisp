import Foundation

/// The user's own companion skin: a solid colour, a gradient, or colours taken from a photo. Only the colours are
/// kept (never the photo). It becomes a full theme: the companion's palette plus the app's accent colours.
public struct CustomSkin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case solid, gradient, photo }

    public var kind: Kind
    /// 1 colour for solid; 2...6 for a gradient or a photo.
    public var colors: [RGB]
    /// How the colours move inside the companion.
    public var style: FluidStyle

    public static let maxColors = 6

    public init(kind: Kind, colors: [RGB], style: FluidStyle = .bands) {
        self.kind = kind; self.colors = colors; self.style = style
    }

    public static let starter = CustomSkin(kind: .gradient, colors: [RGB(hex: 0x3B1FD1), RGB(hex: 0xE0457F), RGB(hex: 0xFFC56A)])

    /// The theme the companion and the app use.
    public var theme: CompanionTheme {
        let base = colors.isEmpty ? Self.starter.colors : Array(colors.prefix(Self.maxColors))
        let palette: [RGB]
        switch kind {
        case .solid:
            // Flat colour with just enough shading to stay alive and readable.
            let c = base[0]
            palette = [c.mixed(with: RGB(0, 0, 0), 0.18), c, c.mixed(with: RGB(1, 1, 1), 0.16)]
        case .gradient, .photo:
            var sorted = base.sorted { $0.luminance < $1.luminance } // darkest → brightest, like the built-ins
            if sorted.count == 1 { sorted.append(sorted[0].mixed(with: RGB(1, 1, 1), 0.35)) }
            palette = sorted
        }
        let (accent, secondary) = Self.accents(from: base)
        let flat = kind == .solid
        return CompanionTheme(id: ThemeCatalog.customID, name: "Custom", palette: palette, style: flat ? .blobs : style,
                              scale: flat ? 1.2 : 2.0, warp: flat ? 0.4 : 1.0, softness: flat ? 0.9 : 0.5,
                              speed: flat ? 0.3 : 0.5, gloss: 0.5, accent: accent, accentSecondary: secondary)
    }

    /// The most colourful colour (made legible behind white text) and the most different second one.
    static func accents(from colors: [RGB]) -> (RGB, RGB) {
        let ranked = colors.sorted { $0.saturation > $1.saturation }
        let first = ranked.first ?? RGB(hex: 0x2B6BFF)
        let second = colors.max { first.distance(to: $0) < first.distance(to: $1) } ?? first
        return (first.legibleAccent, second)
    }
}

extension RGB {
    /// HSV saturation, 0 (grey) ... 1 (vivid).
    public var saturation: Double {
        let mx = max(r, g, b), mn = min(r, g, b)
        return mx == 0 ? 0 : (mx - mn) / mx
    }

    public func distance(to o: RGB) -> Double {
        ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot()
    }

    /// Buttons put white text on the accent: keep it dark enough to read (and not so dark it looks black).
    var legibleAccent: RGB {
        var c = self
        var steps = 0
        while c.luminance > 0.32 && steps < 12 { c = c.mixed(with: RGB(0, 0, 0), 0.12); steps += 1 }
        while c.luminance < 0.04 && steps < 24 { c = c.mixed(with: RGB(1, 1, 1), 0.12); steps += 1 }
        return c
    }
}

extension OverlaySettings {
    /// The theme in use: a built-in one, or the user's own skin.
    public var resolvedTheme: CompanionTheme {
        if cursorThemeID == ThemeCatalog.customID, let customSkin { return customSkin.theme }
        return ThemeCatalog.theme(id: cursorThemeID)
    }
}
