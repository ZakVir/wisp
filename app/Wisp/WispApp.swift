import AppKit
import WispMac

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApplication.delegate` is weak; this keeps the delegate alive for the life of the process.
    private static let shared = AppDelegate()
    private var controller: WispAppController?

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = WispAppController()
        let updater = SparkleUpdater()
        updater.isIdle = { [weak controller] in controller?.isIdle ?? true }
        controller.updater = updater
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening Wisp again from Finder or Spotlight shows Settings (there is no Dock icon). Overlay and
        // recovery panels don't count as open windows.
        if controller?.hasOpenWindow != true { controller?.showSettings() }
        return true
    }
}
