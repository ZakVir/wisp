import AppKit
import AVFoundation
import CoreGraphics
import IOKit.hid
import WispCore

/// Reads and requests the three privacy permissions using public APIs only (no TCC database reads).
@MainActor
public final class PermissionService: ObservableObject {
    @Published public private(set) var snapshot: PermissionSnapshot

    /// Kinds that have been usable at some point on this Mac, so a later loss reads as a revocation.
    private var everGranted: Set<PermissionKind>
    /// Kinds whose system prompt we have already shown (macOS shows each prompt only once).
    private var prompted: Set<PermissionKind>
    /// When we last showed each system prompt. While the user may still be answering, an unknown state
    /// stays `.notDetermined` instead of flipping to `.denied` under the dialog.
    private var promptShownAt: [PermissionKind: Date] = [:]
    private static let answerWindow: TimeInterval = 45
    /// Kinds that `refresh()` saw as not granted at launch. If System Settings later turns them on
    /// while this process runs, some (Screen Recording) only take effect after a relaunch.
    private var deniedAtLaunch: Set<PermissionKind> = []
    private var pollTimer: Timer?
    private let defaults: UserDefaults
    /// Extra capability probe for Input Monitoring: returns false when the event tap cannot be created.
    public var inputMonitoringProbe: (() -> Bool)?

    private static let everGrantedKey = "wisp.permissions.everGranted"
    private static let promptedKey = "wisp.permissions.prompted"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        everGranted = Set((defaults.stringArray(forKey: Self.everGrantedKey) ?? []).compactMap(PermissionKind.init(rawValue:)))
        prompted = Set((defaults.stringArray(forKey: Self.promptedKey) ?? []).compactMap(PermissionKind.init(rawValue:)))
        snapshot = PermissionSnapshot(states: [:])
        refresh()
        deniedAtLaunch = Set(snapshot.missing)
    }

    public func wasEverGranted(_ kind: PermissionKind) -> Bool { everGranted.contains(kind) }

    /// Re-reads every permission. Cheap; safe to call before each hold.
    @discardableResult
    public func refresh() -> PermissionSnapshot {
        var states: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases {
            states[kind] = currentState(kind)
        }
        let next = PermissionSnapshot(states: states)
        let newlyGranted = PermissionKind.allCases.filter { next[$0] == .granted && !everGranted.contains($0) }
        if !newlyGranted.isEmpty {
            everGranted.formUnion(newlyGranted)
            defaults.set(everGranted.map(\.rawValue).sorted(), forKey: Self.everGrantedKey)
        }
        if next != snapshot {
            let changes = PermissionKind.allCases.map { "\($0.rawValue)=\(next[$0].rawValue)" }.joined(separator: " ")
            Log.permissions.info("permission state: \(changes, privacy: .public)")
            snapshot = next
        }
        return next
    }

    /// Debug builds only: `WISP_FAKE_PERMISSIONS="microphone=denied,screenRecording=needsRelaunch"` forces
    /// states so every recovery path can be exercised without changing real privacy settings.
    private static let fakeStates: [PermissionKind: PermissionState] = {
        #if DEBUG
        guard let spec = ProcessInfo.processInfo.environment["WISP_FAKE_PERMISSIONS"] else { return [:] }
        var out: [PermissionKind: PermissionState] = [:]
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: "=").map(String.init)
            if parts.count == 2, let kind = PermissionKind(rawValue: parts[0]), let state = PermissionState(rawValue: parts[1]) {
                out[kind] = state
            }
        }
        return out
        #else
        return [:]
        #endif
    }()

    private func currentState(_ kind: PermissionKind) -> PermissionState {
        if let fake = Self.fakeStates[kind] { return fake }
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied: return .denied
            @unknown default: return .denied
            }

        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted:
                // Granted on paper; confirm the tap can actually be created when a probe is installed.
                if let probe = inputMonitoringProbe, !probe() {
                    return deniedAtLaunch.contains(.inputMonitoring) ? .needsRelaunch : .denied
                }
                return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return answeredOrNeverAsked(.inputMonitoring)
            }

        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            // There is no public tri-state check. If we never asked, the prompt is still available.
            return answeredOrNeverAsked(.screenRecording)
        }
    }

    /// For permissions without a tri-state API: `.notDetermined` until we have asked and the user has had
    /// time to answer; `.denied` afterwards.
    private func answeredOrNeverAsked(_ kind: PermissionKind) -> PermissionState {
        guard prompted.contains(kind) else { return .notDetermined }
        if let shown = promptShownAt[kind], Date().timeIntervalSince(shown) < Self.answerWindow { return .notDetermined }
        return .denied
    }

    /// Shows the system prompt when it is still available, otherwise opens System Settings.
    public func request(_ kind: PermissionKind) async {
        let state = snapshot[kind]
        // A second click while the prompt may still be up (or after it was answered) goes to Settings.
        guard state == .notDetermined, !prompted.contains(kind) || kind == .microphone else {
            openSettings(kind)
            return
        }
        promptShownAt[kind] = Date()
        markPrompted(kind)
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .inputMonitoring:
            // Registers Wisp in the Input Monitoring list and shows the system prompt.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .screenRecording:
            // Registers Wisp in the Screen Recording list; macOS shows a prompt pointing to Settings.
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    public func openSettings(_ kind: PermissionKind) {
        if !NSWorkspace.shared.open(kind.settingsURL) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }

    /// Who currently needs live permission updates (onboarding, settings, recovery card).
    private var pollingOwners: Set<String> = []

    /// Polls once a second while at least one owner (a visible onboarding step, settings tab or recovery
    /// card) needs live updates, so the UI advances by itself when the user flips a switch in Settings.
    public func startPolling(owner: String) {
        pollingOwners.insert(owner)
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stopPolling(owner: String) {
        pollingOwners.remove(owner)
        guard pollingOwners.isEmpty else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func markPrompted(_ kind: PermissionKind) {
        prompted.insert(kind)
        defaults.set(prompted.map(\.rawValue).sorted(), forKey: Self.promptedKey)
    }

    /// Content-free diagnostics for support: versions, permission states, signing identity hash.
    public func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "Wisp \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "?") (\(Bundle.main.bundleURL.path.hasPrefix("/Applications/") ? "in /Applications" : "outside /Applications"))",
        ]
        for kind in PermissionKind.allCases {
            lines.append("\(kind.settingsPaneName): \(snapshot[kind].rawValue)\(everGranted.contains(kind) ? " (was granted before)" : "")")
        }
        lines.append("Displays: \(NSScreen.screens.count) (" + NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)x" }.joined(separator: ", ") + ")")
        return lines.joined(separator: "\n")
    }
}
