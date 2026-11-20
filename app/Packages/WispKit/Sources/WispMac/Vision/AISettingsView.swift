import SwiftUI
import WispCore

/// Settings > AI: provider, API key (saved encrypted in Wisp's Keychain item), endpoint and model.
struct AISettingsView: View {
    @ObservedObject var app: AppState
    @State private var testState: TestState = .idle
    @State private var showAllModels = false
    /// Bumped when a key is saved or removed, so "Test Connection" re-checks availability.
    @State private var keysVersion = 0

    enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
        /// The service said the key itself is wrong (HTTP 401/403), as opposed to being unreachable or busy.
        case rejectedKey
    }

    private var provider: VisionProvider { VisionProvider(configID: app.config.vision.providerID) }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(
                    get: { provider },
                    set: { newValue in
                        app.update {
                            $0.vision.providerID = newValue.rawValue
                            $0.vision.baseURL = newValue.defaultBaseURL
                            // A model name only means something to its own provider.
                            $0.vision.modelID = newValue.defaultModelID
                        }
                        testState = .idle
                    })) {
                    ForEach(VisionProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(app.isLocked("vision.providerID"))
            } footer: {
                Text("Each question sends \(app.config.vision.screensSentDescription), and the question's text, to this provider.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if provider == .openAICompatible {
                Section {
                    CustomProviderForm(app: app)
                        .padding(.vertical, 4)
                } header: {
                    Text("Your AI service")
                }
            } else {
                Section {
                    APIKeyRow(provider: provider, inUse: true) { keysVersion += 1; testState = .idle }
                        .id(provider)
                } header: {
                    Text("Key")
                } footer: {
                    Text("Keys are encrypted and stored only on this Mac. Wisp never asks for your password to use them.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("Model") {
                    if provider == .nvidiaNIM {
                        Toggle("Smart routing", isOn: Binding(get: { app.config.vision.smartRouting },
                                                              set: { v in app.update { $0.vision.smartRouting = v } }))
                        Text(app.config.vision.smartRouting
                             ? "Questions go to Nemotron 3.5 Super VL, the most accurate free model (about 2 seconds), with Nemotron Nano as a quick backup; drawings go to Step 5 Preview."
                             : "Every question goes to the model below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Model", selection: Binding(
                        get: { app.config.vision.modelID },
                        set: { v in app.update { $0.vision.modelID = v } })) {
                        ForEach(showAllModels ? modelOptions : recommendedOptions, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .disabled(app.isLocked("vision.modelID") || (provider == .nvidiaNIM && app.config.vision.smartRouting))
                    if provider == .nvidiaNIM {
                        Toggle("Show all models", isOn: $showAllModels).toggleStyle(.checkbox).font(.callout)
                    }
                    let info = VisionModelCatalog.info(for: app.config.vision.modelID)
                    if !info.note.isEmpty {
                        Text(info.note).font(.callout).foregroundStyle(.secondary)
                    }
                    if provider == .nvidiaNIM {
                        Toggle("If the model fails, try another one", isOn: Binding(
                            get: { !app.config.vision.fallbackModelIDs.isEmpty },
                            set: { on in app.update { $0.vision.fallbackModelIDs = on ? VisionSettings.defaultFallbackModelIDs : [] } }))
                    }
                    HStack {
                        Button("Test Connection", action: test)
                            .disabled(testState == .running || (keysVersion >= 0 && !APIKeyStore.hasKey(for: provider)))
                        switch testState {
                        case .idle: EmptyView()
                        case .running: ProgressView().controlSize(.small)
                        case .ok(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .rejectedKey: Label("\(provider == .anthropic ? "Anthropic" : "NVIDIA") didn't accept that key. Remove it and paste it again.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            InstructionsSection(app: app)
        }
        .formStyle(.grouped)
    }

    /// The models worth choosing (bake-off, FINDINGS §6), plus whatever is selected now.
    private var recommendedOptions: [VisionModelInfo] {
        if provider != .nvidiaNIM { return modelOptions }
        let ids = ["nvidia/nemotron-3-nano-omni-30b-a3b-reasoning", "stepfun-ai/step-5-preview", "nvidia/nemotron-3.5-super-vl-120b-a12b"]
        var list = modelOptions.filter { ids.contains($0.id) }
        if !list.contains(where: { $0.id == app.config.vision.modelID }), let current = modelOptions.first(where: { $0.id == app.config.vision.modelID }) {
            list.append(current)
        }
        return list
    }

    private var modelOptions: [VisionModelInfo] {
        var list = provider.catalog
        if !list.contains(where: { $0.id == app.config.vision.modelID }) {
            list.insert(VisionModelInfo(id: app.config.vision.modelID, displayName: app.config.vision.modelID), at: 0)
        }
        return list
    }


    /// Sends a tiny synthetic test image (no screen content) and checks for a sensible answer.
    private func test() {
        testState = .running
        let config = app.config.vision
        let provider = self.provider
        Task {
            let result = await VisionConnectionTest.run(config: config, provider: provider)
            await MainActor.run { testState = result }
        }
    }
}


/// One provider's key: a secure field until saved, then "Saved" with Remove.
struct APIKeyRow: View {
    let provider: VisionProvider
    let inUse: Bool
    let onChange: () -> Void
    @State private var draft = ""
    @State private var saved = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.displayName)
                if inUse {
                    Text("In use").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
                Spacer()
                if saved {
                    Label("Saved", systemImage: "lock.fill").foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) {
                        APIKeyStore.clear(for: provider)
                        refresh(); onChange()
                    }
                }
            }
            if !saved {
                HStack {
                    SecureField("\(provider.displayName) API key", text: $draft,
                                prompt: Text(provider == .nvidiaNIM ? "nvapi-…" : provider == .anthropic ? "sk-ant-…" : "sk-…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if failed {
                    Text("Couldn't save the key.").font(.callout).foregroundStyle(.orange)
                }
                if provider == .nvidiaNIM {
                    Link("Get a free NVIDIA API key", destination: URL(string: "https://build.nvidia.com/settings/api-keys")!)
                        .font(.callout)
                } else if provider == .anthropic {
                    Link("Get an Anthropic API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.callout)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        saved = APIKeyStore.isSaved(for: provider)
        draft = ""
    }

    private func save() {
        failed = !APIKeyStore.save(draft, for: provider)
        if !failed { refresh(); onChange() }
    }
}

enum VisionConnectionTest {
    static func run(config: VisionSettings, provider: VisionProvider) async -> AISettingsView.TestState {
        guard let base = URL(string: config.baseURL) else { return .failed("That address isn't valid.") }
        // 64×64 white square: no user content leaves the Mac during the test.
        let size = 64
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return .failed("Couldn't make the test image")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return .failed("Couldn't make the test image") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)

        let client = VisionClient(baseURL: base, policy: ConsentPolicyGate(disclosureAccepted: { true }),
                                  apiKey: { APIKeyStore.key(for: provider) }, requiresKey: provider.requiresKey, wire: provider.wire)
        let request = VisionRequest(model: config.modelInfo,
                                    systemPrompt: "Reply with one short line.", userText: "What colour is this image?",
                                    jpegs: [data as Data], maxTokens: 20, temperature: 0)
        let start = ProcessInfo.processInfo.systemUptime
        var text = ""
        do {
            for try await chunk in client.stream(request, frontmostBundleID: nil, firstTokenTimeout: 30, totalTimeout: 45) {
                text += chunk
            }
        } catch let error as VisionError {
            if case .http(let code, _) = error, code == 401 || code == 403 { return .rejectedKey }
            return .failed(error.userMessage)
        } catch {
            return .failed("Couldn't reach the AI service. Check your internet.")
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        return text.isEmpty ? .failed("The AI service didn't reply. Try again.") : .ok(String(format: "Connected. Answered in %.1f seconds.", seconds))
    }
}


/// "About you": the user's own words about themselves and how they like answers, sent with every question.
struct InstructionsSection: View {
    @ObservedObject var app: AppState
    @State private var draft = ""
    @State private var loaded = false
    private static let examples = ["I'm new to Macs: explain simply, one step at a time.",
                                   "Keep answers very short.",
                                   "I edit videos in Final Cut Pro for work."]

    var body: some View {
        Section {
            Picker("Answer length", selection: Binding(get: { app.config.vision.answerLength },
                                                       set: { v in app.update { $0.vision.answerLength = v } })) {
                Text("Short").tag("short")
                Text("Normal").tag("normal")
                Text("Detailed").tag("detailed")
            }
            .pickerStyle(.segmented)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 70, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .writingToolsBehavior(.disabled)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("For example: I'm new to Macs, so explain simply.")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: draft) {
                    if draft.count > VisionSettings.maxInstructions { draft = String(draft.prefix(VisionSettings.maxInstructions)) }
                    guard loaded else { return }
                    let text = draft
                    app.update { $0.vision.instructions = text }
                }
                .disabled(app.isLocked("vision.instructions"))
                .accessibilityLabel("About you")
            HStack(spacing: 6) {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example.components(separatedBy: ":").first ?? example) {
                        draft = draft.isEmpty ? example : draft + " " + example
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
                }
            }
        } header: {
            Text("About you")
        } footer: {
            HStack(alignment: .top) {
                Text("Tell Wisp about yourself or how you like answers. It's sent with every question.")
                Spacer()
                Text("\(draft.count)/\(VisionSettings.maxInstructions)").monospacedDigit()
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear {
            draft = app.config.vision.instructions
            DispatchQueue.main.async { loaded = true }
        }
    }
}
