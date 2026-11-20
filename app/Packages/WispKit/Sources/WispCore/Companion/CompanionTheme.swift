import Foundation

/// An sRGB colour with components in 0...1.
public struct RGB: Equatable, Sendable, Codable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    /// From a hex literal such as 0x1E7BFF.
    public init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
    public func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }
    /// Relative luminance (WCAG).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// How the fluid pattern inside the companion moves and looks.
public enum FluidStyle: String, Codable, Sendable {
    /// Marbled, flowing bands of colour (liquid-light look).
    case bands
    /// Large, soft, blurred blobs that drift (lava-lamp look).
    case blobs
    /// Long bright streaks, like light rays (cosmic look).
    case rays
}

/// A companion theme: the palette and the parameters of the animated fluid fill.
public struct CompanionTheme: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    /// Palette from darkest to brightest; the fluid value 0...1 is mapped across these stops.
    public var palette: [RGB]
    public var style: FluidStyle
    /// Pattern zoom: higher = more, smaller swirls.
    public var scale: Double
    /// Domain-warp strength: higher = more twisted, liquid swirls.
    public var warp: Double
    /// Softness 0 (crisp edges between colours) ... 1 (heavily blurred).
    public var softness: Double
    /// Animation speed multiplier.
    public var speed: Double
    /// Strength of the glossy highlight on the top edge.
    public var gloss: Double
    /// Colour used for the app's accents (buttons, waveform, captions) when this theme is active.
    public var accent: RGB
    /// Secondary accent for gradients.
    public var accentSecondary: RGB

    public init(id: String, name: String, palette: [RGB], style: FluidStyle, scale: Double, warp: Double,
                softness: Double, speed: Double, gloss: Double, accent: RGB, accentSecondary: RGB) {
        precondition(palette.count >= 2 && palette.count <= 8, "palette needs 2...8 stops")
        self.id = id; self.name = name; self.palette = palette; self.style = style; self.scale = scale
        self.warp = warp; self.softness = softness; self.speed = speed; self.gloss = gloss
        self.accent = accent; self.accentSecondary = accentSecondary
    }

    /// The palette colour at `t` (0...1), linearly interpolated between evenly spaced stops.
    public func color(at t: Double) -> RGB {
        let x = min(max(t, 0), 1) * Double(palette.count - 1)
        let i = min(Int(x), palette.count - 2)
        return palette[i].mixed(with: palette[i + 1], x - Double(i))
    }
}

/// The built-in themes. Palettes were sampled from the reference cursor artwork the user supplied, then
/// rendered procedurally (no third-party image assets are used).
public enum ThemeCatalog {
    public static let defaultID = "aurora"
    /// The user's own skin (OverlaySettings.customSkin).
    public static let customID = "custom"

    public static let all: [CompanionTheme] = [
        CompanionTheme(id: "aurora", name: "Aurora",
                       palette: [RGB(hex: 0x0A0B4A), RGB(hex: 0x2B2BD6), RGB(hex: 0x1F7BFF), RGB(hex: 0x24D2F2),
                                 RGB(hex: 0xC4F52C), RGB(hex: 0xF3FFD2)],
                       style: .bands, scale: 2.6, warp: 1.1, softness: 0.35, speed: 0.55, gloss: 0.55,
                       accent: RGB(hex: 0x2B6BFF), accentSecondary: RGB(hex: 0x9BE832)),
        CompanionTheme(id: "quasar", name: "Quasar",
                       palette: [RGB(hex: 0x16103F), RGB(hex: 0x4B1BC9), RGB(hex: 0x9A1FF0), RGB(hex: 0xE62491),
                                 RGB(hex: 0xFF7B1C), RGB(hex: 0xFFD9B8)],
                       style: .blobs, scale: 1.7, warp: 0.9, softness: 0.75, speed: 0.45, gloss: 0.5,
                       accent: RGB(hex: 0xC4248F), accentSecondary: RGB(hex: 0xFF8A2A)),
        CompanionTheme(id: "magma", name: "Magma",
                       palette: [RGB(hex: 0x5E0F55), RGB(hex: 0xB4175F), RGB(hex: 0xF0402D), RGB(hex: 0xFF8E1E),
                                 RGB(hex: 0xFFC56A), RGB(hex: 0xFFEBC0)],
                       style: .blobs, scale: 1.9, warp: 1.0, softness: 0.7, speed: 0.4, gloss: 0.45,
                       accent: RGB(hex: 0xE8452C), accentSecondary: RGB(hex: 0xB4175F)),
        CompanionTheme(id: "spice", name: "Spice Latte",
                       palette: [RGB(hex: 0x3A1205), RGB(hex: 0x7A2808), RGB(hex: 0xC2500E), RGB(hex: 0xF08A1F),
                                 RGB(hex: 0xFFC060), RGB(hex: 0xFFEACB)],
                       style: .bands, scale: 1.5, warp: 0.8, softness: 0.55, speed: 0.35, gloss: 0.85,
                       accent: RGB(hex: 0xD9681A), accentSecondary: RGB(hex: 0x8A3410)),
        CompanionTheme(id: "storm", name: "Storm",
                       palette: [RGB(hex: 0x03072E), RGB(hex: 0x0C1C8F), RGB(hex: 0x2343E6), RGB(hex: 0x5E8DFF),
                                 RGB(hex: 0xB9DCFF), RGB(hex: 0xF5FBFF)],
                       style: .bands, scale: 2.0, warp: 1.0, softness: 0.45, speed: 0.6, gloss: 0.5,
                       accent: RGB(hex: 0x2F5BFF), accentSecondary: RGB(hex: 0x8FC8FF)),
        CompanionTheme(id: "lagoon", name: "Lagoon",
                       palette: [RGB(hex: 0x0A2E9E), RGB(hex: 0x0E6FC9), RGB(hex: 0x10B4A6), RGB(hex: 0x30E6D3),
                                 RGB(hex: 0x95F6CC), RGB(hex: 0xF0FFFA)],
                       style: .bands, scale: 1.8, warp: 0.95, softness: 0.6, speed: 0.45, gloss: 0.6,
                       accent: RGB(hex: 0x0FA9A0), accentSecondary: RGB(hex: 0x1E66D9)),
        CompanionTheme(id: "ember", name: "Ember",
                       palette: [RGB(hex: 0x24082A), RGB(hex: 0x7A1F5E), RGB(hex: 0xD2347A), RGB(hex: 0xFF8A1C),
                                 RGB(hex: 0x41EFD3), RGB(hex: 0xE2FFF7)],
                       style: .bands, scale: 2.3, warp: 1.15, softness: 0.4, speed: 0.55, gloss: 0.5,
                       accent: RGB(hex: 0xE0457F), accentSecondary: RGB(hex: 0x2FD9C0)),
        CompanionTheme(id: "nebula", name: "Nebula",
                       palette: [RGB(hex: 0x2E0A8F), RGB(hex: 0x5C1FE6), RGB(hex: 0x9A2CFF), RGB(hex: 0xDB3BF5),
                                 RGB(hex: 0xFF6A2B), RGB(hex: 0xFFF3DE)],
                       style: .rays, scale: 2.0, warp: 0.85, softness: 0.3, speed: 0.5, gloss: 0.55,
                       accent: RGB(hex: 0x7B2CFF), accentSecondary: RGB(hex: 0xFF6A2B)),
        CompanionTheme(id: "sunset", name: "City Sunset",
                       palette: [RGB(hex: 0x12101E), RGB(hex: 0x1F8FAF), RGB(hex: 0xC4141F), RGB(hex: 0xFF5E1A),
                                 RGB(hex: 0xFFB43A), RGB(hex: 0xFFEE73)],
                       style: .blobs, scale: 1.9, warp: 1.15, softness: 1.0, speed: 0.35, gloss: 0.4,
                       accent: RGB(hex: 0xF06A1E), accentSecondary: RGB(hex: 0x2EC4D6)),
        CompanionTheme(id: "solar", name: "Solar Flare",
                       palette: [RGB(hex: 0x4E0C45), RGB(hex: 0x9C0F4A), RGB(hex: 0xE0222A), RGB(hex: 0xFF6A00),
                                 RGB(hex: 0xFFC23A), RGB(hex: 0xFFF2B5)],
                       style: .bands, scale: 1.6, warp: 0.95, softness: 0.95, speed: 0.6, gloss: 0.5,
                       accent: RGB(hex: 0xFF5A14), accentSecondary: RGB(hex: 0xB0124E)),
        CompanionTheme(id: "ametrine", name: "Ametrine",
                       palette: [RGB(hex: 0x3D0AD6), RGB(hex: 0x6A12F5), RGB(hex: 0xA51CFF), RGB(hex: 0xE53CFF),
                                 RGB(hex: 0xFFC43D), RGB(hex: 0xFFF3A8)],
                       style: .bands, scale: 2.4, warp: 1.1, softness: 0.45, speed: 0.55, gloss: 0.55,
                       accent: RGB(hex: 0x8E1CFF), accentSecondary: RGB(hex: 0xFFC43D)),
        CompanionTheme(id: "forest", name: "Forest",
                       palette: [RGB(hex: 0x021A10), RGB(hex: 0x063D27), RGB(hex: 0x0C6B3D), RGB(hex: 0x1BA35A),
                                 RGB(hex: 0x62D884), RGB(hex: 0xD6F9C8)],
                       style: .bands, scale: 1.9, warp: 1.0, softness: 0.5, speed: 0.45, gloss: 0.55,
                       accent: RGB(hex: 0x1E9A55), accentSecondary: RGB(hex: 0x8ED65A)),
        CompanionTheme(id: "rosegold", name: "Rose Gold",
                       palette: [RGB(hex: 0x330C20), RGB(hex: 0x74264A), RGB(hex: 0xB84D6C), RGB(hex: 0xE07F86),
                                 RGB(hex: 0xF0B07A), RGB(hex: 0xFBE0C0)],
                       style: .bands, scale: 2.0, warp: 1.05, softness: 0.45, speed: 0.45, gloss: 0.7,
                       accent: RGB(hex: 0xD0607A), accentSecondary: RGB(hex: 0xE9A56B)),
        CompanionTheme(id: "graphite", name: "Graphite",
                       palette: [RGB(hex: 0x111317), RGB(hex: 0x2B3038), RGB(hex: 0x4F5966), RGB(hex: 0x8A96A6),
                                 RGB(hex: 0xC9D2DC), RGB(hex: 0xF7F9FB)],
                       style: .bands, scale: 2.2, warp: 0.9, softness: 0.5, speed: 0.4, gloss: 0.65,
                       accent: RGB(hex: 0x5B6B80), accentSecondary: RGB(hex: 0x9AA7B8)),
    ]

    public static func theme(id: String) -> CompanionTheme {
        all.first { $0.id == id } ?? all[0]
    }
}
