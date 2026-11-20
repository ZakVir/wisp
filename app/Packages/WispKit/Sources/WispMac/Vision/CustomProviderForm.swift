import SwiftUI
import WispCore

/// Connects Wisp to any OpenAI-compatible service: its address (…/v1), a key if it needs one, a model that accepts
/// images, and, for models Wisp doesn't know, how they give screen positions. Used by setup and Settings > AI.
struct CustomProviderForm: View {
    @ObservedObject var app: AppState
    /// Called after a successful connection test.
    var onConnected: () -> Void = {}

    @State private var address = ""
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var modelDraft = ""
    @State private var found: [String] = []
    @State private var finding = false
    @State private var findError: String?
    @State private var state: AISettingsView.TestState = .idle
    @State private var showAdvanced = false

    private let provider = VisionProvider.openAICompatible

    private var addressValid: Bool {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host?.isEmpty == false
    }

    private var canConnect: Bool {
        addressValid && !modelDraft.trimmingCharacters(in: .whitespaces).isEmpty && state != .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Server address", hint: "The service's OpenAI-compatible address, usually ending in /v1. For example https://api.openai.com/v1, or http://localhost:11434/v1 for Ollama.") {
                TextField("Server address", text: $address, prompt: Text("https://api.example.com/v1"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(app.isLocked("vision.baseURL"))
                if !address.isEmpty && !addressValid {
                    Text("Enter a full address starting with https:// or http://.").font(.callout).foregroundStyle(.orange)
                }
            }

            field("API key", hint: "Leave empty if your server doesn't need one (most local servers). It's encrypted and kept only on this Mac.") {
                if keySaved {
                    HStack {
                        Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Remove") {
                            APIKeyStore.clear(for: provider)
                            keySaved = false
                            state = .idle
                        }
                    }
                } else {
                    SecureField("API key", text: $keyDraft, prompt: Text("Optional"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
            }

            field("Model", hint: "The exact model name. It must understand images. Find Models asks the server what it offers.") {
                HStack {
                    TextField("Model", text: $modelDraft, prompt: Text("e.g. gpt-4o or qwen2.5vl"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .disabled(app.isLocked("vision.modelID"))
                    if found.isEmpty {
                        Button(finding ? "Finding…" : "Find Models", action: findModels)
                            .disabled(!addressValid || finding)
                    } else {
                        Menu("Choose") {
                            ForEach(found, id: \.self) { id in Button(id) { modelDraft = id } }
                        }
                        .fixedSize()
                    }
                }
                if let findError { Text(findError).font(.callout).foregroundStyle(.orange) }
            }

            DisclosureGroup("More options", isExpanded: $showAdvanced) {
                Picker("Screen positions", selection: Binding(
                    get: { app.config.vision.customCoordinateSpace },
                    set: { v in app.update { $0.vision.customCoordinateSpace = v } })) {
                    Text("Pixels in the screenshot (most models)").tag(ModelCoordinateSpace.imagePixels)
                    Text("0 to 1000 (Gemini, Qwen, Gemma)").tag(ModelCoordinateSpace.normalized1000)
                    Text("0 to 1").tag(ModelCoordinateSpace.normalizedUnit)
                }
                .padding(.top, 6)
                Text("How the model says where things are on screen. If the cursor points at the wrong place, try another option.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
                switch state {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small); Text("Checking the connection…").foregroundStyle(.secondary)
                case .ok(let message): Label(message, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .rejectedKey: Label("The server didn't accept that key.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            let vision = app.config.vision
            address = vision.providerID == provider.rawValue ? vision.baseURL : ""
            modelDraft = vision.providerID == provider.rawValue ? vision.modelID : ""
            keySaved = APIKeyStore.isSaved(for: provider)
        }
        .onChange(of: address) { _, _ in found = []; findError = nil }
    }

    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            content()
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyForRequests: String? {
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? APIKeyStore.key(for: provider) : typed
    }

    private func findModels() {
        finding = true
        findError = nil
        let base = address, key = keyForRequests
        Task {
            do {
                let ids = try await ModelListFetcher.fetch(baseURL: base, key: key)
                await MainActor.run {
                    found = ids
                    finding = false
                    if modelDraft.isEmpty, let first = ids.first { modelDraft = first }
                }
            } catch {
                await MainActor.run {
                    finding = false
                    findError = (error as? ModelListFetcher.Failure)?.message ?? ModelListFetcher.Failure.unreachable.message
                }
            }
        }
    }

    private func connect() {
        let base = address.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelID = modelDraft.trimmingCharacters(in: .whitespaces)
        let typedKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty {
            guard APIKeyStore.save(typedKey, for: provider) else { state = .failed("Couldn't save the key. Try again."); return }
            keyDraft = ""
            keySaved = true
        }
        app.update {
            $0.vision.providerID = provider.rawValue
            $0.vision.baseURL = base
            $0.vision.modelID = modelID
        }
        address = base
        state = .running
        let config = app.config.vision
        Task {
            let result = await VisionConnectionTest.run(config: config, provider: provider)
            await MainActor.run {
                state = result
                if case .ok = result { onConnected() }
            }
        }
    }
}
