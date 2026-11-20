import Foundation
import ServiceManagement
import WispCore

/// "Open Wisp at login" via the system login-item service (no helper app). macOS shows its own notice the first
/// time; the user can also manage it in System Settings > General > Login Items.
@MainActor
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// A login item must point at a copy that stays put (not a mounted disk image or the Downloads folder).
    public static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    /// Returns the resulting state.
    @discardableResult
    public static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}
