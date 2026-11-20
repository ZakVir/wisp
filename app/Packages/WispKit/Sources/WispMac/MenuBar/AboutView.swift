import SwiftUI
import WispCore

/// App updates, implemented by the app target with Sparkle (WispKit doesn't link Sparkle itself).
@MainActor
public protocol AppUpdater: AnyObject {
    /// A feed URL and signing key are set in this build; otherwise update checks are off.
    var isConfigured: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func checkForUpdates()
}

/// Settings > About: version, updates, and the open-source parts Wisp is built on.
struct AboutView: View {
    let updater: AppUpdater?
    var openCheckup: (() -> Void)? = nil
    var openWhatsNew: (() -> Void)? = nil
    @State private var stats: UsageStats?
    @State private var automatic = false
    @State private var install = false

    /// Wisp's own icon (macOS's Clear/Tinted icon styles would show a grey version of the app icon).
    private static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }()

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: Self.appIcon)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wisp").font(.title2.weight(.semibold))
                        Text(version).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let openWhatsNew {
                        Button("What's New…", action: openWhatsNew)
                    }
                }
                .padding(.vertical, 4)
            }

            if let stats, stats.answered > 0 {
                Section("Your Wisp") {
                    LabeledContent("Questions answered", value: stats.answeredThisWeek > 0 ? "\(stats.answered) (\(stats.answeredThisWeek) this week)" : "\(stats.answered)")
                    if let ms = stats.medianStartMs {
                        LabeledContent("Starts talking", value: String(format: "about %.1f s after you let go", Double(ms) / 1000))
                    }
                    if stats.answeredLocally > 0 {
                        LabeledContent("Answered on this Mac, without the AI", value: "\(stats.answeredLocally)")
                    }
                }
            }

            if let openCheckup {
                Section {
                    HStack {
                        Text("Something not working? The check-up tests every part of Wisp and shows how to fix what isn't.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Check Wisp…", action: openCheckup)
                    }
                }
            }

            Section("Updates") {
                if let updater, updater.isConfigured {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { automatic },
                        set: { automatic = $0; updater.automaticallyChecksForUpdates = $0 }))
                    Toggle("Install updates automatically", isOn: Binding(
                        get: { install },
                        set: { install = $0; updater.automaticallyDownloadsUpdates = $0 }))
                        .disabled(!automatic)
                    HStack {
                        Text("Update checks send only Wisp's version and your macOS version.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                } else {
                    Text("This build doesn't check for updates.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Built with") {
                credit("Moonshine", "speech recognition, MIT License")
                credit("Kokoro-82M", "voice, Apache License 2.0")
                credit("FluidAudio by FluidInference", "Kokoro on Core ML, Apache License 2.0")
                credit("Sparkle", "updates, MIT License")
                credit("Clicky by Farza", "ideas for pointing and multi-display, MIT License")
            }
        }
        .formStyle(.grouped)
        .task {
            // From the local timing log (no content); read off the main thread.
            stats = await Task.detached(priority: .utility) { UsageStats.from(TimingLog.shared.load()) }.value
        }
        .onAppear {
            automatic = updater?.automaticallyChecksForUpdates ?? false
            install = updater?.automaticallyDownloadsUpdates ?? false
        }
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
