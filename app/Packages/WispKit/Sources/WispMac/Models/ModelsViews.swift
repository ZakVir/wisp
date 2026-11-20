import SwiftUI
import WispCore

/// Plain-language status for one model.
private func statusText(_ state: ModelState, offline: Bool) -> String {
    switch state {
    case .notInstalled where offline, .downloading where offline: return "Waiting for an internet connection…"
    case .notInstalled: return "Not downloaded yet"
    case .downloading(_, let bytes, let total):
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return "Downloading · \(fmt.string(fromByteCount: bytes)) of \(fmt.string(fromByteCount: total))"
    case .verifying: return "Checking the files…"
    case .preparing: return "Getting ready for this Mac…"
    case .ready: return "Ready"
    case .failed(let failure): return failure.userMessage
    }
}

/// A determinate progress card for one model (also used in onboarding).
struct ModelCard: View {
    var model: ModelEntry
    var state: ModelState
    var offline = false
    /// Onboarding shows a tighter card (no license line) so three models fit on one page.
    var compact = false
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: model.kind == .speechToText ? "waveform.badge.mic" : "speaker.wave.2")
                    .foregroundStyle(WispStyle.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(Self.friendlyName(model)).font(.headline)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            progress
            HStack {
                Text(statusText(state, offline: offline))
                    .font(.callout)
                    .foregroundStyle(isFailure ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer()
                if case .failed(let failure) = state, failure.isRetryable {
                    Button("Try Again", action: onRetry)
                }
                if state == .notInstalled && !offline {
                    Button("Download", action: onRetry)
                }
                if state.isReady {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("\(Self.friendlyName(model)) ready")
                }
            }
            if !compact {
                Text("\(model.displayName) · \(model.license) license · runs on this Mac")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(compact ? 12 : 14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .contain)
    }

    /// What the model does, in plain words (the technical name is in the small print in Settings).
    static func friendlyName(_ model: ModelEntry) -> String {
        if model.kind == .speechToText { return "Speech recognition" }
        return model.id.contains("voices") ? "More voices" : "Wisp's voice"
    }

    private var isFailure: Bool { if case .failed = state { return true } else { return false } }

    @ViewBuilder private var progress: some View {
        switch state {
        case .downloading(let fraction, _, _):
            ProgressView(value: fraction).accessibilityLabel(Self.friendlyName(model)).accessibilityValue("\(Int(fraction * 100)) percent")
        case .verifying, .preparing:
            // Keep a bar (not a spinner) through every phase so the UI doesn't jump.
            ProgressView(value: 1).tint(WispStyle.accentSecondary).accessibilityLabel(Self.friendlyName(model))
        case .ready:
            ProgressView(value: 1).tint(.green).accessibilityLabel(Self.friendlyName(model))
        case .notInstalled, .failed:
            ProgressView(value: 0).accessibilityLabel(Self.friendlyName(model))
        }
    }
}

/// Settings > Speech Models.
struct ModelsSettingsView: View {
    @ObservedObject var models: ModelManager
    @ObservedObject var app: AppState
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                ForEach(models.manifest.models) { model in
                    ModelCard(model: model, state: models.states[model.id] ?? .notInstalled, offline: models.isOffline) {
                        models.ensureInstalled(model)
                    }
                }
            } header: {
                Text("On-device speech")
            } footer: {
                Text("Your voice is turned into text, and answers are spoken, entirely on this Mac. Wisp can hear you once the speech model is ready; until the voice is ready, it answers in the Mac's system voice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Maintenance") {
                HStack {
                    if app.config.models.manifestURL != nil {
                        Button("Check for Updates") { Task { await models.checkForUpdates(force: true) } }
                    }
                    Button("Repair") { models.repair() }
                        .help("Re-checks every file and downloads anything missing or damaged.")
                    Spacer()
                    Button("Remove Models…", role: .destructive) { confirmRemove = true }
                }
                Text("Stored in ~/Library/Application Support/Wisp/Models")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove the speech models?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { models.removeAll() }
        } message: {
            Text("Wisp can't hear your questions until you download them again (Download or Repair).")
        }
    }
}

/// Onboarding step: models download in the background; the user can continue right away.
struct ModelsOnboardingStep: View {
    @ObservedObject var models: ModelManager

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "arrow.down.circle",
                       title: "Getting Wisp's voice ready",
                       subtitle: "Wisp understands you and speaks on this Mac, so your voice never leaves it. This one-time download keeps going in the background.")
            VStack(spacing: 10) {
                ForEach(models.manifest.models) { model in
                    ModelCard(model: model, state: models.states[model.id] ?? .notInstalled, offline: models.isOffline, compact: true) {
                        models.ensureInstalled(model)
                    }
                }
            }
            Text(allReady ? "All set. Speech works entirely on this Mac."
                 : models.isOffline ? "You can continue now. The download starts by itself when you're back online."
                 : "You can continue now. The download keeps going in the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        // Setup always gets the speech models going (also after they were removed in Settings).
        .onAppear {
            for model in models.manifest.models {
                switch models.states[model.id] ?? .notInstalled {
                case .notInstalled: models.ensureInstalled(model)
                case .failed(let failure) where failure.isRetryable: models.ensureInstalled(model)
                default: break
                }
            }
        }
    }

    private var allReady: Bool {
        models.manifest.models.allSatisfy { models.states[$0.id]?.isReady == true }
    }
}
