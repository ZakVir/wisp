import SwiftUI
import WispCore

/// Additional settings tabs contributed by features (voice, models, vision model, cursor theme).
public struct SettingsTab: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let content: () -> AnyView

    public init<V: View>(id: String, title: String, symbol: String, @ViewBuilder content: @escaping () -> V) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.content = { AnyView(content()) }
    }
}

/// Which Settings tab is showing, so menu items can open the one that fixes a problem.
@MainActor
public final class SettingsNavigation: ObservableObject {
    @Published public var tab = "general"
    public init() {}
}

public struct SettingsView: View {
    @ObservedObject var app: AppState
    @ObservedObject var nav: SettingsNavigation
    var extraTabs: [SettingsTab]
    var updater: AppUpdater?

    public init(app: AppState, nav: SettingsNavigation = SettingsNavigation(), extraTabs: [SettingsTab] = [], updater: AppUpdater? = nil) {
        self.app = app
        self.nav = nav
        self.extraTabs = extraTabs
        self.updater = updater
    }

    public var body: some View {
        TabView(selection: $nav.tab) {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ForEach(extraTabs) { tab in
                tab.content()
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab.id)
            }
            PermissionsSettings(app: app)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag("permissions")
            PrivacySettingsView(app: app)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag("privacy")
            AboutView(updater: updater, openCheckup: app.openCheckup, openWhatsNew: app.openWhatsNew)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 600)
        .frame(minHeight: 640)
        .tint(WispStyle.accent)
    }
}

struct GeneralSettings: View {
    @ObservedObject var app: AppState
    /// Preset chords, plus the current one if it was recorded as a custom shortcut.
    static func options(including current: ModifierSet) -> [ModifierSet] {
        let presets: [ModifierSet] = [[.control, .option], [.option, .command], [.control, .command], [.control, .shift]]
        return presets.contains(current) ? presets : presets + [current]
    }

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Keys") {
                    Picker("", selection: Binding(
                        get: { app.effectiveChord.modifiers },
                        set: { mods in app.setChordModifiers(mods) })) {
                        ForEach(Self.options(including: app.effectiveChord.modifiers), id: \.rawValue) { mods in
                            Text("\(mods.symbols)   \(mods.names)").tag(mods)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                .disabled(app.isLocked("chord"))
                LabeledContent("Your own") { ShortcutRecorderButton(app: app) }
                Picker("Mode", selection: Binding(
                    get: { app.effectiveChord.mode },
                    set: { mode in app.setChordMode(mode) })) {
                    Text("Hold to talk").tag(ChordMode.hold)
                    Text("Press to start, press again to stop").tag(ChordMode.toggle)
                }
                .disabled(app.isLocked("chord"))
                LabeledContent("Double-tap to type a question") {
                    HStack(spacing: 12) {
                        Picker("Key", selection: Binding(get: { app.config.typeKey }, set: { v in app.update { $0.typeKey = v } })) {
                            Text("⌃ Control").tag("control")
                            Text("⌥ Option").tag("option")
                            Text("⌘ Command").tag("command")
                            Text("⇧ Shift").tag("shift")
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!app.config.typeToAsk)
                        Toggle("Double-tap to type a question", isOn: Binding(get: { app.config.typeToAsk },
                                                                              set: { v in app.update { $0.typeToAsk = v } }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .disabled(app.effectiveChord.modifiers == app.config.typeKeyModifier)
                Toggle("Show typed answers in a card", isOn: Binding(get: { app.config.answerCard },
                                                                     set: { v in app.update { $0.answerCard = v } }))
                    .help("After a typed question, the whole answer stays on screen for a moment, with Copy.")
                Toggle("Show spoken answers in a card too", isOn: Binding(get: { app.config.answerCardAlways },
                                                                          set: { v in app.update { $0.answerCardAlways = v } }))
                Toggle("Let Wisp open apps and websites for you", isOn: Binding(get: { app.config.allowWebActions },
                                                                                set: { v in app.update { $0.allowWebActions = v } }))
                    .help("Light help only: open an app, do one menu command, search the web or a site. With Better answers on, Wisp really clicks and types; it never deletes, sends or buys anything.")
                Toggle("Guide me step by step", isOn: Binding(get: { app.config.guideSteps },
                                                              set: { v in app.update { $0.guideSteps = v } }))
                    .help("After a how-to answer, click where Wisp points and it shows the next step.")
                if app.voiceOverRunning && app.effectiveChord.conflictsWithVoiceOver {
                    Label("VoiceOver uses Control + Option. Choose another shortcut.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if app.isLocked("chord") {
                    Label("Managed by your organization", systemImage: "building.2")
                        .foregroundStyle(.secondary)
                }
            }
            OpenAtLoginSection()
            MicrophoneSection(app: app)
            Section("Voice") {
                HStack {
                    Picker("Voice", selection: Binding(get: { app.config.speech.voiceID },
                                                       set: { v in app.update { $0.speech.voiceID = v } })) {
                        ForEach(VoiceCatalog.all) { voice in
                            let ready = app.voiceAvailable?(voice.id) ?? true
                            Text("\(voice.name), \(voice.detail)\(ready ? "" : " – not ready yet")").tag(voice.id)
                        }
                    }
                    .disabled(app.isLocked("speech.voiceID"))
                    Button("Preview") { app.previewVoice?(app.config.speech.voiceID) }
                        .disabled(!(app.voiceAvailable?(app.config.speech.voiceID) ?? true))
                        .help((app.voiceAvailable?(app.config.speech.voiceID) ?? true) ? "" : "This voice is still downloading.")
                }
                LabeledContent("Speed") {
                    CommitSlider(value: app.config.speech.rate, range: 0.7...1.4, step: 0.05, label: "Speed") { v in
                        app.update { $0.speech.rate = v }
                    }
                }
                LabeledContent("Volume") {
                    CommitSlider(value: app.config.speech.volume, range: 0...1, label: "Volume") { v in
                        app.update { $0.speech.volume = v }
                    }
                }
                .disabled(!app.config.speech.speakAnswers)
                Toggle("Speak answers out loud", isOn: Binding(get: { app.config.speech.speakAnswers },
                                                               set: { v in app.update { $0.speech.speakAnswers = v } }))
                if !app.config.speech.speakAnswers {
                    Text("Answers appear as captions only, at the pace Wisp would speak them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Captions and sound") {
                Toggle("Show captions", isOn: Binding(get: { app.config.speech.showCaptions },
                                                      set: { v in app.update { $0.speech.showCaptions = v } }))
                Picker("Caption size", selection: Binding(get: { app.config.speech.captionSize },
                                                          set: { v in app.update { $0.speech.captionSize = v } })) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                .pickerStyle(.segmented)
                .disabled(!app.config.speech.effectiveShowCaptions)
                Picker("Caption position", selection: Binding(get: { app.config.speech.captionPosition },
                                                              set: { v in app.update { $0.speech.captionPosition = v } })) {
                    Text("Next to the pointer").tag("pointer")
                    Text("Bottom of the screen").tag("bottom")
                }
                .disabled(!app.config.speech.effectiveShowCaptions)
                Toggle("Show what Wisp heard", isOn: Binding(get: { app.config.speech.showHeard },
                                                             set: { v in app.update { $0.speech.showHeard = v } }))
                    .help("Your question appears for a moment before the answer, so you can tell if Wisp misheard.")
                Toggle("Answer quietly during calls", isOn: Binding(get: { app.config.speech.quietDuringCalls },
                                                                    set: { v in app.update { $0.speech.quietDuringCalls = v } }))
                    .help("When another app is using the microphone, answers appear as captions and in a card instead of out loud.")
                Toggle("Play listening sounds", isOn: Binding(get: { app.config.speech.earcons },
                                                              set: { v in app.update { $0.speech.earcons = v } }))
            }
            SettingsFileSection(app: app)
            Section {
                HStack {
                    Text("Watch the welcome again and go back through setup: AI service, permissions, shortcut and a practice question.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Replay Welcome…") { app.replayWelcome?() }
                }
            } header: {
                Text("Welcome and setup")
            } footer: {
                Text("Your settings, keys and downloads stay as they are.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionsSettings: View {
    @ObservedObject var app: AppState
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { kind in
                    let state = app.permissions.snapshot[kind]
                    HStack {
                        PermissionStatusRow(kind: kind, state: state)
                        if state != .granted {
                            PermissionActionButtons(app: app, kind: kind, state: state)
                        }
                    }
                }
            } footer: {
                Text("Wisp checks these every time you use the shortcut. If one turns off, Wisp shows a card explaining how to turn it back on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                AppDetailsRow(app: app, compact: true)
            } header: {
                Text("Optional")
            }
            Section("Support") {
                HStack {
                    Text("If something isn't working, copy this and send it to whoever is helping you. It has versions and permission settings, never anything you said or saw.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.permissions.diagnostics(), forType: .string)
                        copied = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { app.permissions.startPolling(owner: "settings") }
        .onDisappear { app.permissions.stopPolling(owner: "settings") }
    }
}

struct PrivacySettingsView: View {
    @ObservedObject var app: AppState

    var body: some View {
        Form {
            Section("Where your data goes") {
                ExplainerRow(symbol: "mic", text: "Speech is turned into text on this Mac. Audio never leaves it.")
                ExplainerRow(symbol: "icloud.and.arrow.up", text: "Each question sends \(app.config.vision.screensSentDescription), and the question's text, to \(app.config.vision.providerDisplayName)'s cloud AI service (\(app.config.vision.modelDisplayName)). Wisp doesn't store them.")
                ExplainerRow(symbol: "waveform", text: "Answers are spoken by a voice that runs on this Mac.")
                ExplainerRow(symbol: "doc.on.clipboard", text: "Your clipboard is only sent when you ask about what you copied (\"what does what I copied mean?\"), and only with that question.")
                if app.config.vision.readAppControls && UIContextReader.isAllowed {
                    ExplainerRow(symbol: "list.bullet.rectangle", text: "With Better answers on, the names, states and positions of the front app's buttons, its menu commands, the control under your pointer and any text you've selected go with the question. Passwords are never read, and text you've typed only goes if you select it.")
                }
            }
            if !app.config.vision.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    ExplainerRow(symbol: "person.text.rectangle", text: "What you wrote under Settings > AI > About you goes with each question.")
                }
            }
            Section {
                AppDetailsRow(app: app)
            }
            Section {
                Toggle("Include my other displays", isOn: Binding(get: { app.config.vision.captureAllDisplays },
                                                                 set: { v in app.update { $0.vision.captureAllDisplays = v } }))
                    .disabled(app.isLocked("vision.captureAllDisplays"))
            } footer: {
                Text("Lets Wisp point at things on another monitor. Off: only the display you're using is sent.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            PrivateAppsSection(app: app)
            Section {
                Toggle("Keep history on this Mac", isOn: Binding(get: { app.config.privacy.keepHistory },
                                                                 set: { v in
                                                                     app.update { $0.privacy.keepHistory = v }
                                                                     if !v { try? FileManager.default.removeItem(at: AppPaths.applicationSupport.appendingPathComponent("history.json")) }
                                                                 }))
            } footer: {
                Text("Off: History (in the Wisp menu) is cleared when Wisp quits. On: questions and answers are saved as text on this Mac, never screenshots or audio.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(app.notesCount == 0 ? "No notes" : "\(app.notesCount) note\(app.notesCount == 1 ? "" : "s")")
                    Spacer()
                    Button("Clear Notes") { app.clearNotes?() }
                        .disabled(app.notesCount == 0)
                }
            } header: {
                Text("Notes")
            } footer: {
                Text("Things you ask Wisp to remember (“remember that…”) stay on this Mac and are never sent to the AI.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("On this Mac") {
                Toggle("Keep timing measurements (no content)", isOn: Binding(get: { app.config.privacy.localTimingLog },
                                                                             set: { v in app.update { $0.privacy.localTimingLog = v } }))
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings > General > Microphone: which input Wisp records from.
struct MicrophoneSection: View {
    @ObservedObject var app: AppState
    @State private var devices: [AudioDevices.Device] = []
    @State private var systemDefault: String = ""

    var body: some View {
        Section {
            Picker("Record from", selection: Binding(
                get: { app.config.speech.inputDeviceUID ?? "" },
                set: { uid in app.update { $0.speech.inputDeviceUID = uid.isEmpty ? nil : uid } })) {
                Text(systemDefault.isEmpty ? "System default" : "System default (\(systemDefault))").tag("")
                ForEach(devices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
                if let chosen = app.config.speech.inputDeviceUID, !devices.contains(where: { $0.uid == chosen }) {
                    Text("Previously chosen microphone (not connected)").tag(chosen)
                }
            }
            .disabled(app.isLocked("speech.inputDeviceUID"))
        } header: {
            Text("Microphone")
        } footer: {
            Text("With System default, a Bluetooth headset's microphone is skipped in favor of the built-in one, so your headphones keep their full sound quality.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        devices = AudioDevices.inputs().sorted { ($0.isBuiltIn ? 0 : 1, $0.name) < ($1.isBuiltIn ? 0 : 1, $1.name) }
        systemDefault = AudioDevices.preferredInput()?.name ?? ""
    }
}

/// Settings > General: start Wisp with the Mac.
struct OpenAtLoginSection: View {
    @State private var enabled = LoginItem.isEnabled

    var body: some View {
        Section {
            Toggle("Open Wisp when you log in", isOn: Binding(get: { enabled }, set: { enabled = LoginItem.setEnabled($0) }))
                .disabled(!LoginItem.isInstalled && !enabled)
        } footer: {
            if !LoginItem.isInstalled {
                Text("Move Wisp to your Applications folder to have it open at login.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { enabled = LoginItem.isEnabled }
    }
}

/// A slider that saves once when you let go (dragging doesn't write settings on every tick).
struct CommitSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var label: String
    var commit: (Double) -> Void
    @State private var draft: Double?
    @State private var dragging = false

    var body: some View {
        // Keyboard and VoiceOver adjustments never start a drag: those save straight away.
        let binding = Binding(get: { draft ?? value }, set: { v in
            if dragging { draft = v } else { commit(v) }
        })
        Group {
            if let step {
                Slider(value: binding, in: range, step: step) { Text(label) } onEditingChanged: { editing in finish(editing) }
            } else {
                Slider(value: binding, in: range) { Text(label) } onEditingChanged: { editing in finish(editing) }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 240)
    }

    private func finish(_ editing: Bool) {
        dragging = editing
        guard !editing, let d = draft else { return }
        commit(d)
        draft = nil
    }
}


/// Settings > Privacy > Private apps: apps Wisp never sees.
struct PrivateAppsSection: View {
    @ObservedObject var app: AppState
    /// Password managers and similar, offered when installed.
    private static let suggestions = ["com.1password.1password", "com.apple.Passwords", "com.apple.keychainaccess",
                                      "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal"]

    var body: some View {
        Section {
            ForEach(app.config.privacy.privateApps, id: \.self) { id in
                HStack(spacing: 10) {
                    Image(nsImage: Self.icon(for: id)).resizable().frame(width: 20, height: 20)
                    Text(Self.name(for: id))
                    Spacer()
                    Button("Remove") { app.update { $0.privacy.privateApps.removeAll { $0 == id } } }
                        .controlSize(.small)
                }
            }
            HStack {
                Button("Add App…", action: addApp)
                let missing = Self.suggestions.filter { !app.config.privacy.privateApps.contains($0) && Self.isInstalled($0) }
                if !missing.isEmpty {
                    Button("Add Password Apps") { app.update { $0.privacy.privateApps += missing } }
                }
            }
            .disabled(app.isLocked("privacy.privateApps"))
        } header: {
            Text("Private apps")
        } footer: {
            Text("Wisp never sees these apps: their windows are left out of every screenshot, and their buttons and text are never read.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Keep Private"
        panel.message = "Choose apps Wisp should never see."
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { $0 != Bundle.main.bundleIdentifier && !app.config.privacy.privateApps.contains($0) }
        guard !ids.isEmpty else { return }
        app.update { $0.privacy.privateApps += ids }
    }

    static func isInstalled(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }

    static func name(for id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for id: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}


/// Settings > General > Settings file: export this Mac's settings, import them on another (no keys).
struct SettingsFileSection: View {
    @ObservedObject var app: AppState
    @State private var status: String?

    var body: some View {
        Section {
            HStack {
                Button("Export Settings…", action: export)
                Button("Import Settings…", action: importFile)
                Spacer()
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("Settings file")
        } footer: {
            Text("Set up several Macs the same way: export here, import on the other Mac. AI keys are never included. IT can also install the file as Wisp's managed settings to set them for everyone.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Wisp Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConfigTransfer.exportData(app.config).write(to: url, options: .atomic)
            status = "Exported to \(url.lastPathComponent)."
        } catch {
            status = "Couldn't save the file."
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            let imported = try ConfigTransfer.importing(data, over: app.config)
            app.update { $0 = imported }
            status = "Imported. If this Mac doesn't have an AI key yet, add one under AI."
        } catch {
            status = "That file isn't a Wisp settings file."
        }
    }
}
