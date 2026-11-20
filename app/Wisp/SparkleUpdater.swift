import Foundation
import Sparkle
import WispMac

/// Sparkle-backed updates. Only started when the build has a feed URL (Release builds), so other builds never touch
/// the network for updates. Defaults: check daily, download quietly, and install at an idle moment. Wisp lives in the
/// menu bar and is rarely quit, so waiting for a quit would mean never updating.
@MainActor
final class SparkleUpdater: NSObject, AppUpdater, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    let isConfigured: Bool
    /// True when Wisp isn't listening, thinking or speaking (set by the app).
    var isIdle: () -> Bool = { true }
    private var installWhenIdle: (() -> Void)?
    private var idleTimer: Timer?

    override init() {
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        isConfigured = URL(string: feed)?.scheme == "https" && !key.isEmpty
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: isConfigured, updaterDelegate: self, userDriverDelegate: self)
    }

    // MARK: SPUUpdaterDelegate

    /// A downloaded update is ready: install it the next time Wisp is idle (Sparkle quits and relaunches the app).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let handler = InstallHandler(run: immediateInstallHandler)
        MainActor.assumeIsolated {
            installWhenIdle = handler.run
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installIfIdle() }
            }
            installIfIdle()
        }
        return true
    }

    private func installIfIdle() {
        guard let install = installWhenIdle, isIdle() else { return }
        installWhenIdle = nil
        idleTimer?.invalidate()
        idleTimer = nil
        install()
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A background (menu bar) app: let Sparkle show its reminders gently instead of stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    var canCheckForUpdates: Bool { isConfigured && controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}

/// Sparkle's install callback, carried onto the main actor (Sparkle calls its delegate on the main thread).
private struct InstallHandler: @unchecked Sendable {
    let run: () -> Void
}
