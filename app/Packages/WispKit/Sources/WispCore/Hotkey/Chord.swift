import Foundation

/// Modifier keys that can make up a push-to-talk chord. Independent of AppKit so it
/// can be stored in config and unit-tested.
public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control  = ModifierSet(rawValue: 1 << 0)
    public static let option   = ModifierSet(rawValue: 1 << 1)
    public static let command  = ModifierSet(rawValue: 1 << 2)
    public static let shift    = ModifierSet(rawValue: 1 << 3)
    public static let function = ModifierSet(rawValue: 1 << 4)

    /// One symbol per key in Apple's canonical order (Fn, Control, Option, Shift, Command).
    public var symbolList: [String] {
        var list: [String] = []
        if contains(.function) { list.append("fn") }
        if contains(.control) { list.append("⌃") }
        if contains(.option) { list.append("⌥") }
        if contains(.shift) { list.append("⇧") }
        if contains(.command) { list.append("⌘") }
        return list
    }

    /// Compact form for menus, e.g. "⌃⌥" or "fn⌃".
    public var symbols: String { symbolList.joined() }

    /// Spoken/readable names, e.g. "Control + Option".
    public var names: String {
        var parts: [String] = []
        if contains(.function) { parts.append("Fn") }
        if contains(.control) { parts.append("Control") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Command") }
        return parts.joined(separator: " + ")
    }

    public var count: Int { rawValue.nonzeroBitCount }
}

/// How the chord triggers listening.
public enum ChordMode: String, Codable, Sendable, CaseIterable {
    /// Listen while held, stop on release (default).
    case hold
    /// Press once to start, press again to stop (for users who cannot hold keys).
    case toggle
}

/// A modifier-only push-to-talk shortcut.
public struct Chord: Codable, Hashable, Sendable {
    public var modifiers: ModifierSet
    public var mode: ChordMode

    public init(modifiers: ModifierSet, mode: ChordMode = .hold) {
        self.modifiers = modifiers
        self.mode = mode
    }

    /// The default chord. Collides with the VoiceOver modifier (see `recommendedDefault`).
    public static let controlOption = Chord(modifiers: [.control, .option])
    /// Default offered when VoiceOver is running (does not include the VO keys together).
    public static let optionCommand = Chord(modifiers: [.option, .command])

    /// Chords need at least two modifiers so ordinary typing (Shift, a lone Command) never triggers listening.
    /// Fn is not allowed: macOS doesn't report it reliably and dictation apps (Wispr Flow, macOS Dictation)
    /// claim it, so a saved Fn chord falls back to the default.
    public var isValid: Bool { modifiers.count >= 2 && !modifiers.contains(.function) }

    /// True when the chord contains both Control and Option, VoiceOver's default modifier.
    public var conflictsWithVoiceOver: Bool { modifiers.isSuperset(of: [.control, .option]) }

    public var displayName: String { modifiers.names }
    /// "hold Control + Option" or "press Control + Option", matching the mode.
    public var usePhrase: String { mode == .hold ? "hold \(displayName)" : "press \(displayName)" }
    /// "while you hold Control + Option" or "after you press Control + Option".
    public var whilePhrase: String { mode == .hold ? "while you hold \(displayName)" : "after you press \(displayName)" }
    public var symbols: String { modifiers.symbols }

    /// Default chord for this Mac given whether VoiceOver is running.
    public static func recommendedDefault(voiceOverRunning: Bool) -> Chord {
        voiceOverRunning ? .optionCommand : .controlOption
    }
}
