import Foundation

/// The macOS privacy permissions the base product needs.
public enum PermissionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case microphone
    case inputMonitoring
    case screenRecording

    public var id: String { rawValue }

    /// Name as it appears in System Settings > Privacy & Security.
    /// What the permission is for, in plain words (the checklist label).
    public var friendlyName: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Noticing your shortcut (Input Monitoring)"
        case .screenRecording: "Seeing your screen (Screen Recording)"
        }
    }

    public var settingsPaneName: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen & System Audio Recording"
        }
    }

    /// `x-apple.systempreferences` anchor for the pane.
    public var settingsAnchor: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }

    public var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")!
    }
}

public enum PermissionState: String, Codable, Sendable, Equatable {
    case granted
    /// Never asked; the system prompt can still be shown.
    case notDetermined
    /// The user said no (or turned it off). Only System Settings can fix it.
    case denied
    /// Blocked by an administrator or parental controls.
    case restricted
    /// Turned on in System Settings, but this running process cannot use it until it relaunches.
    case needsRelaunch

    public var isUsable: Bool { self == .granted }
}

/// A point-in-time view of every permission.
public struct PermissionSnapshot: Equatable, Sendable {
    public var states: [PermissionKind: PermissionState]

    public init(states: [PermissionKind: PermissionState]) {
        self.states = states
    }

    public subscript(kind: PermissionKind) -> PermissionState {
        states[kind] ?? .notDetermined
    }

    /// Permissions that are not yet usable, in the order the user should fix them.
    public var missing: [PermissionKind] {
        PermissionKind.allCases.filter { !self[$0].isUsable }
    }

    public var allGranted: Bool { missing.isEmpty }

    /// Kinds that were usable in `previous` but are not now (revoked while running, or monthly consent lapsed).
    public func revoked(since previous: PermissionSnapshot) -> [PermissionKind] {
        PermissionKind.allCases.filter { previous[$0].isUsable && !self[$0].isUsable }
    }
}

/// What the menu bar shows.
public enum Readiness: Equatable, Sendable {
    case ready
    case needsAttention([PermissionKind])

    public init(_ snapshot: PermissionSnapshot) {
        self = snapshot.allGranted ? .ready : .needsAttention(snapshot.missing)
    }
}

/// A plain-language card explaining one missing permission and how to fix it.
public struct RecoveryCard: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Show the system permission prompt (only possible while `.notDetermined`).
        case requestAccess(PermissionKind)
        /// Open the right System Settings pane.
        case openSettings(PermissionKind)
        /// Quit and reopen the app so a new grant takes effect.
        case relaunch
    }

    public var kind: PermissionKind
    public var title: String
    public var message: String
    public var primary: Action
    public var primaryLabel: String
    public var secondary: Action?
    public var secondaryLabel: String?

    /// Builds the card for `kind` in `state`. `chord` is the user's actual shortcut, never hard-coded.
    /// `wasPreviouslyGranted` distinguishes a revocation or lapsed monthly consent from a first-time setup.
    public static func make(kind: PermissionKind, state: PermissionState, chord: Chord, wasPreviouslyGranted: Bool) -> RecoveryCard? {
        if state == .granted { return nil }
        let pane = kind.settingsPaneName

        switch state {
        case .granted:
            return nil
        case .needsRelaunch:
            return RecoveryCard(kind: kind,
                                title: "Almost there",
                                message: "\(pane) is turned on. Wisp needs to reopen to start using it.",
                                primary: .relaunch, primaryLabel: "Reopen Wisp",
                                secondary: nil, secondaryLabel: nil)
        case .restricted:
            return RecoveryCard(kind: kind,
                                title: "\(pane) is managed",
                                message: "Your administrator controls \(pane) on this Mac, so Wisp can't turn it on. Ask them to allow Wisp.",
                                primary: .openSettings(kind), primaryLabel: "Open Settings",
                                secondary: nil, secondaryLabel: nil)
        case .notDetermined, .denied:
            let canPrompt = state == .notDetermined
            let primary: Action = canPrompt ? .requestAccess(kind) : .openSettings(kind)
            let primaryLabel = canPrompt ? "Allow" : "Open Settings"
            let secondary: Action? = (kind == .microphone || canPrompt) ? nil : .relaunch
            let secondaryLabel: String? = secondary == nil ? nil : "Reopen Wisp"

            let title: String
            let message: String
            switch kind {
            case .microphone:
                title = wasPreviouslyGranted ? "I can't hear you anymore" : "Let me hear your question"
                message = canPrompt
                    ? "Wisp only listens \(chord.whilePhrase). The orange dot in the menu bar shows when it is listening. Click Allow, then confirm."
                    : "Microphone access is off. Turn on Wisp in Privacy & Security > \(pane)."
            case .inputMonitoring:
                title = wasPreviouslyGranted ? "Your shortcut stopped working" : "Let me notice your shortcut"
                message = canPrompt
                    ? "Wisp watches only for \(chord.displayName), so it knows when to listen. Click Allow, then turn on Wisp in the list macOS shows."
                    : "Wisp watches only for \(chord.displayName), so it knows when to listen. Turn on Wisp in Privacy & Security > \(pane), then reopen Wisp."
            case .screenRecording:
                title = wasPreviouslyGranted ? "I can't see your screen right now" : "Let me see what you're asking about"
                message = wasPreviouslyGranted
                    ? "macOS asks every so often to confirm screen access, or it was turned off. Turn on Wisp in Privacy & Security > \(pane), then reopen Wisp."
                    : (canPrompt
                       ? "Wisp takes a screenshot only \(chord.whilePhrase), uses it to answer, and doesn't keep it. Click Allow, then allow Wisp when macOS asks."
                       : "Wisp takes a screenshot only \(chord.whilePhrase), uses it to answer, and doesn't keep it. Turn on Wisp in Privacy & Security > \(pane), then reopen Wisp.")
            }
            return RecoveryCard(kind: kind, title: title, message: message,
                                primary: primary, primaryLabel: primaryLabel,
                                secondary: secondary, secondaryLabel: secondaryLabel)
        }
    }
}
