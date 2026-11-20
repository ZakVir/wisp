import SwiftUI
import WispCore

/// Live shortcut test: keycaps light up as they are pressed; a hold shows success.
struct ShortcutTestView: View {
    @ObservedObject var app: AppState
    @ObservedObject var keys: LiveKeyState

    init(app: AppState) {
        self.app = app
        self.keys = app.keys
    }

    var body: some View {
        let chord = app.effectiveChord
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Array(chord.modifiers.symbolList.enumerated()), id: \.offset) { index, symbol in
                    let mod = Self.modifier(at: index, of: chord.modifiers)
                    Keycap(symbol: symbol, name: mod.names, pressed: keys.held.contains(mod))
                }
            }
            Text(status(chord))
                .font(.callout)
                .foregroundStyle(keys.chordActive ? WispStyle.accent : .secondary)
                .animation(.easeOut(duration: 0.15), value: keys.chordActive)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity)
        .onAppear { keys.isPracticing = true; keys.successfulHolds = 0 }
        .onDisappear { keys.isPracticing = false }
    }

    private func status(_ chord: Chord) -> String {
        if app.permissions.snapshot[.inputMonitoring] != .granted {
            return "Turn on Input Monitoring below, then try your shortcut."
        }
        if keys.chordActive { return chord.mode == .hold ? "Listening… let go when you're done." : "Listening… press again to stop." }
        if keys.successfulHolds > 0 { return "That works. Wisp heard your shortcut." }
        if case .cancelled(.tooShort)? = keys.lastEvent { return "Hold a little longer, then let go." }
        if case .cancelled(.otherKeyPressed)? = keys.lastEvent { return "Only hold \(chord.displayName), no other keys." }
        return chord.mode == .hold ? "Try it: hold \(chord.displayName) and say hello." : "Try it: press \(chord.displayName), say hello, press again."
    }

    /// The modifier for the n-th symbol in canonical order.
    static func modifier(at index: Int, of set: ModifierSet) -> ModifierSet {
        let order: [ModifierSet] = [.function, .control, .option, .shift, .command]
        return order.filter { set.contains($0) }[index]
    }
}

struct Keycap: View {
    var symbol: String
    /// Read by VoiceOver ("Control"), since symbols like ⌃ aren't.
    var name: String
    var pressed: Bool

    var body: some View {
        Text(symbol)
            .font(.system(size: 20, weight: .medium, design: .rounded))
            .frame(minWidth: 46, minHeight: 42)
            .padding(.horizontal, 4)
            .foregroundStyle(pressed ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(pressed ? AnyShapeStyle(WispStyle.accent) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.secondary.opacity(pressed ? 0 : 0.35)))
            .shadow(color: .black.opacity(pressed ? 0.0 : 0.12), radius: 0, x: 0, y: pressed ? 0 : 2)
            .offset(y: pressed ? 2 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
            .accessibilityLabel(name)
            .accessibilityValue(pressed ? "pressed" : "")
    }
}

/// "Record Shortcut" control: hold any two or more modifier keys and let go to set them.
struct ShortcutRecorderButton: View {
    @ObservedObject var app: AppState
    @ObservedObject var keys: LiveKeyState
    @State private var recording = false

    init(app: AppState) {
        self.app = app
        self.keys = app.keys
    }

    var body: some View {
        HStack(spacing: 10) {
            if recording {
                Text(keys.held.count > 0 ? keys.held.symbols : "Hold your keys…")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(WispStyle.accent)
                    .frame(minWidth: 110, alignment: .trailing)
                Button("Cancel") { stop() }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Button("Record Shortcut…") { start() }
                        .disabled(app.isLocked("chord") || app.permissions.snapshot[.inputMonitoring] != .granted)
                        .help("Hold two or more modifier keys, then let go.")
                    if app.permissions.snapshot[.inputMonitoring] != .granted {
                        Text("Allow Input Monitoring first (Permissions tab).").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        keys.recorder = { mods in
            app.setChordModifiers(mods)
            recording = false
        }
    }

    private func stop() {
        recording = false
        keys.cancelRecording()
    }
}
