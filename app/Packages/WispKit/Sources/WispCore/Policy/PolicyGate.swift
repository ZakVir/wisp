import Foundation

/// Every outbound network call is described and passed through a `PolicyGate` first.
/// The personal edition allows everything the user has consented to; the company edition can plug in
/// rules (blocked apps, allowed hosts, redaction) without touching call sites.
public struct NetworkIntent: Sendable, Equatable {
    public enum Purpose: String, Sendable {
        /// Screenshot + transcript to the vision model.
        case visionRequest
        /// Model catalogue / health checks against the vision provider (no user content).
        case providerMetadata
        /// Speech model manifest or file download (no user content).
        case modelDownload
        /// App update check (no user content).
        case appUpdate
    }

    public var purpose: Purpose
    public var host: String
    /// True when the request carries user content (screenshot, audio, transcript).
    public var carriesUserContent: Bool
    /// Bundle identifier of the frontmost app when the screenshot was taken, if any.
    public var frontmostBundleID: String?

    public init(purpose: Purpose, host: String, carriesUserContent: Bool, frontmostBundleID: String? = nil) {
        self.purpose = purpose
        self.host = host
        self.carriesUserContent = carriesUserContent
        self.frontmostBundleID = frontmostBundleID
    }
}

public enum PolicyDecision: Equatable, Sendable {
    case allow
    /// Blocked; `userMessage` is safe to show and speak.
    case deny(userMessage: String)
}

public protocol PolicyGate: Sendable {
    func evaluate(_ intent: NetworkIntent) -> PolicyDecision
}

/// Personal-edition policy: content may only leave the Mac after the user accepted the cloud disclosure.
public struct ConsentPolicyGate: PolicyGate {
    private let disclosureAccepted: @Sendable () -> Bool

    public init(disclosureAccepted: @escaping @Sendable () -> Bool) {
        self.disclosureAccepted = disclosureAccepted
    }

    public func evaluate(_ intent: NetworkIntent) -> PolicyDecision {
        if intent.carriesUserContent && !disclosureAccepted() {
            return .deny(userMessage: "Before I can look at your screen, open Welcome Guide from the Wisp menu and finish setup.")
        }
        return .allow
    }
}
