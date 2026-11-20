import Foundation

/// Raw keyboard facts fed to the state machine (from an event tap, or from tests).
public enum KeyInput: Equatable, Sendable {
    /// The set of modifiers currently held changed.
    case modifiersChanged(ModifierSet, at: TimeInterval)
    /// A non-modifier key went down (while anything is held, this means "the user is typing a shortcut").
    case keyDown(at: TimeInterval)
    /// The event source was interrupted (tap disabled, sleep, secure input). Releases any hold.
    case interrupted(at: TimeInterval)
}

/// What the app should do in response.
public enum ChordEvent: Equatable, Sendable {
    /// Start listening (key-down moment; capture the screenshot now).
    case began(at: TimeInterval)
    /// Stop listening normally; `heldFor` is the hold duration in seconds.
    case ended(at: TimeInterval, heldFor: TimeInterval)
    /// Abandon this turn: discard audio, do not answer.
    case cancelled(reason: CancelReason)
}

public enum CancelReason: String, Equatable, Sendable {
    /// Released too quickly to be a question (an accidental tap).
    case tooShort
    /// Another key was pressed: the chord was part of a different shortcut.
    case otherKeyPressed
    /// An extra modifier joined the chord.
    case extraModifier
    /// The keyboard stream was interrupted.
    case interrupted
    /// Held longer than the maximum; ended to protect privacy and memory.
    case tooLong
}

/// Turns modifier changes into push-to-talk begin/end/cancel events.
///
/// Hold mode: listening begins the instant exactly the chord's modifiers are down (so the first word is
/// never lost) and ends when any of them is released. Pressing another key or adding a modifier cancels,
/// because the user was typing a different shortcut (for example Control-Option-arrow).
///
/// Toggle mode: a clean press-and-release of the chord (no other key, released within `tapWindow`)
/// starts listening; the next clean press-and-release stops it.
public struct ChordStateMachine: Sendable {
    public var chord: Chord
    /// Holds shorter than this are treated as accidental taps (hold mode).
    public var minimumHold: TimeInterval = 0.25
    /// Toggle mode: the chord must be released within this window to count as a tap.
    public var tapWindow: TimeInterval = 0.5
    /// Safety limit for a single question.
    public var maximumHold: TimeInterval = 120

    private enum Phase: Equatable {
        case idle
        /// Hold mode: listening.
        case holding(since: TimeInterval)
        /// Hold mode: the chord turn was cancelled; wait until every chord key is up before re-arming.
        case waitingForRelease
        /// Toggle mode: chord down, not yet known to be a tap.
        case toggleArming(since: TimeInterval, wasListening: Bool, listeningSince: TimeInterval?)
        /// Toggle mode: listening, chord released.
        case toggleListening(since: TimeInterval)
    }

    private var phase: Phase = .idle
    private var held: ModifierSet = []

    public init(chord: Chord) {
        self.chord = chord
    }

    /// Forgets any hold in progress (after a chord change or a missed release).
    public mutating func reset() {
        phase = .idle
        held = []
    }

    public var isListening: Bool {
        switch phase {
        case .holding, .toggleListening: return true
        case .toggleArming(_, let wasListening, _): return wasListening
        default: return false
        }
    }

    /// Feeds one input; returns zero or one event.
    public mutating func handle(_ input: KeyInput) -> ChordEvent? {
        switch chord.mode {
        case .hold: return handleHold(input)
        case .toggle: return handleToggle(input)
        }
    }

    /// Call periodically (e.g. every second) so an over-long hold is ended even without key events.
    public mutating func tick(now: TimeInterval) -> ChordEvent? {
        switch phase {
        case .holding(let since) where now - since > maximumHold:
            phase = .waitingForRelease
            return .cancelled(reason: .tooLong)
        case .toggleListening(let since) where now - since > maximumHold:
            phase = .idle
            return .cancelled(reason: .tooLong)
        default:
            return nil
        }
    }

    private mutating func handleHold(_ input: KeyInput) -> ChordEvent? {
        switch input {
        case .modifiersChanged(let mods, let t):
            held = mods
            switch phase {
            case .idle:
                if mods == chord.modifiers { phase = .holding(since: t); return .began(at: t) }
                return nil
            case .holding(let since):
                if mods == chord.modifiers { return nil }
                if mods.isStrictSuperset(of: chord.modifiers) {
                    phase = .waitingForRelease
                    return .cancelled(reason: .extraModifier)
                }
                // A chord key was released.
                phase = mods.isDisjoint(with: chord.modifiers) ? .idle : .waitingForRelease
                let heldFor = t - since
                return heldFor < minimumHold ? .cancelled(reason: .tooShort) : .ended(at: t, heldFor: heldFor)
            case .waitingForRelease:
                if mods.isDisjoint(with: chord.modifiers) { phase = .idle }
                return nil
            case .toggleArming, .toggleListening:
                phase = .idle
                return nil
            }
        case .keyDown:
            if case .holding = phase {
                phase = .waitingForRelease
                return .cancelled(reason: .otherKeyPressed)
            }
            return nil
        case .interrupted:
            held = []
            if case .holding = phase {
                phase = .idle
                return .cancelled(reason: .interrupted)
            }
            phase = .idle
            return nil
        }
    }

    private mutating func handleToggle(_ input: KeyInput) -> ChordEvent? {
        switch input {
        case .modifiersChanged(let mods, let t):
            let previous = held
            held = mods
            switch phase {
            case .idle, .toggleListening:
                let listeningSince: TimeInterval? = { if case .toggleListening(let s) = phase { return s }; return nil }()
                if mods == chord.modifiers && previous != chord.modifiers {
                    phase = .toggleArming(since: t, wasListening: listeningSince != nil, listeningSince: listeningSince)
                }
                return nil
            case .toggleArming(let since, let wasListening, let listeningSince):
                if mods == chord.modifiers { return nil }
                if mods.isStrictSuperset(of: chord.modifiers) {
                    // Not a clean tap: go back to whatever we were doing.
                    phase = wasListening ? .toggleListening(since: listeningSince ?? since) : .waitingForRelease
                    return nil
                }
                // Released: a clean tap only if quick enough.
                guard t - since <= tapWindow else {
                    phase = wasListening ? .toggleListening(since: listeningSince ?? since) : .idle
                    return nil
                }
                if wasListening {
                    phase = .idle
                    let start = listeningSince ?? since
                    return .ended(at: t, heldFor: t - start)
                } else {
                    phase = .toggleListening(since: t)
                    return .began(at: t)
                }
            case .waitingForRelease:
                if mods.isDisjoint(with: chord.modifiers) { phase = .idle }
                return nil
            case .holding:
                phase = .idle
                return nil
            }
        case .keyDown:
            if case .toggleArming(let since, let wasListening, let listeningSince) = phase {
                phase = wasListening ? .toggleListening(since: listeningSince ?? since) : .waitingForRelease
            }
            return nil
        case .interrupted:
            held = []
            let wasListening = isListening
            phase = .idle
            return wasListening ? .cancelled(reason: .interrupted) : nil
        }
    }
}
