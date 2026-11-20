import AppKit
import WispCore

/// File locations used by the app.
public enum AppPaths {
    /// `~/Library/Application Support/Wisp`
    public static var applicationSupport: URL {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        // Fresh-install testing: `WISP_HOME=/some/empty/folder` gives a brand-new user's settings, models and keys
        // without touching the real ones.
        if let home = ProcessInfo.processInfo.environment["WISP_HOME"], !home.isEmpty { base = URL(fileURLWithPath: home) }
        #endif
        let url = base.appendingPathComponent("Wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `~/Library/Application Support/Wisp/Models`
    public static var models: URL { applicationSupport.appendingPathComponent("Models", isDirectory: true) }

    /// `~/Library/Caches/com.zakvirani.wisp`
    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(Log.subsystem, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Quits and reopens the app, e.g. after a permission that needs a restart was granted.
@MainActor
public enum Relauncher {
    /// Launch argument that tells the new instance to resume onboarding where it left off.
    public static let resumeArgument = "--wisp-resume"

    public static func relaunch(resumeOnboarding: Bool) {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit before opening a fresh instance (so it is not just re-activated).
        // Values are passed as positional arguments, never interpolated into the script.
        let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; if [ "$3" = "1" ]; then open -n "$2" --args "$4"; else open -n "$2"; fi"#
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), path,
                             resumeOnboarding ? "1" : "0", resumeArgument]
        do {
            try process.run()
            Log.app.info("relaunching")
            NSApp.terminate(nil)
        } catch {
            Log.app.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
