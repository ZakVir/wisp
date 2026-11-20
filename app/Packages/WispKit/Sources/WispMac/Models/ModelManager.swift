import Combine
import Foundation
import Network
import WispCore

/// Loads (warms) an installed model so first use is fast. Registered per runtime by the speech engines.
public typealias ModelWarmer = @Sendable (_ directory: URL, _ model: ModelEntry) async throws -> Void

/// Installs and maintains the on-device speech models with no manual steps:
/// signed manifest → disk check → resumable background download with retry/backoff → SHA-256 verify of every
/// file → atomic move into `Models/<id>/<version>` → warm-up → ready. Also: throttled update checks with
/// side-by-side install and switch-over, Repair (re-hash and re-fetch), Remove, offline pre-provisioned
/// folders, mirrors, and a policy gate before any network call.
@MainActor
public final class ModelManager: ObservableObject {
    public struct Dependencies {
        public var root: URL
        public var session: DownloadSession
        public var policy: PolicyGate
        public var settings: () -> ModelSourceSettings
        /// Free bytes on the models volume (injectable to simulate a full disk).
        public var availableBytes: (URL) -> Int64?
        public var backoff: Backoff
        /// Maximum attempts per file before giving up for this round.
        public var maxAttempts: Int
        public var sleep: @Sendable (Double) async -> Void

        public init(root: URL, session: DownloadSession, policy: PolicyGate, settings: @escaping () -> ModelSourceSettings,
                    availableBytes: @escaping (URL) -> Int64? = { DiskSpace.available(at: $0) },
                    backoff: Backoff = Backoff(), maxAttempts: Int = 6,
                    sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
            self.root = root; self.session = session; self.policy = policy; self.settings = settings
            self.availableBytes = availableBytes; self.backoff = backoff; self.maxAttempts = maxAttempts; self.sleep = sleep
        }
    }

    @Published public private(set) var manifest: ModelManifest
    @Published public private(set) var states: [String: ModelState] = [:]
    /// No network right now (downloads wait and resume by themselves).
    @Published public private(set) var isOffline = false

    /// Plain-language reason speech-to-text isn't usable yet, or nil when it is.
    public var speechProblem: String? {
        guard let stt = manifest.models.first(where: { $0.kind == .speechToText }) else { return nil }
        switch states[stt.id] ?? .notInstalled {
        case .ready: return nil
        case .failed: return "My speech model didn't finish installing. Open Wisp Settings, then Speech, and choose Repair."
        case .verifying, .preparing: return "My speech model is getting ready. Try again in a few seconds."
        default:
            return isOffline ? "I'm waiting for an internet connection to finish setting up my speech model."
                             : "My speech model is still downloading. Try again in a minute."
        }
    }

    public let layout: ModelLayout
    private var deps: Dependencies
    private var warmers: [String: ModelWarmer] = [:]
    /// One install task per model id, tagged so a finishing (cancelled) task never clears its replacement.
    private var installTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var pathMonitor: NWPathMonitor?
    /// Remove Models deletes files only after cancelled installs have stopped; new installs wait for it.
    private var pendingRemoval: Task<Void, Never>?
    private var retryTimer: Timer?
    private var networkAvailable = true
    /// Called before files of a model are deleted (Remove/Repair/upgrade), so engines can unload them.
    public var willRemove: ((ModelEntry) -> Void)?

    private static let lastCheckKey = "wisp.models.lastUpdateCheck"
    private var cachedManifestURL: URL { layout.root.appendingPathComponent("manifest-cache.json") }

    public init(manifest: ModelManifest, dependencies: Dependencies) {
        self.manifest = manifest
        self.deps = dependencies
        self.layout = ModelLayout(root: dependencies.root)
        try? FileManager.default.createDirectory(at: dependencies.root, withIntermediateDirectories: true)
        // A previously downloaded, newer signed manifest wins over the bundled one.
        if let cached = Self.loadCachedManifest(at: layout.root.appendingPathComponent("manifest-cache.json")),
           ManifestCodec.isNewer(cached.manifestVersion, than: manifest.manifestVersion) {
            self.manifest = cached
        }
        for model in self.manifest.models { states[model.id] = .notInstalled }
        startNetworkMonitor()
    }

    /// The manifest shipped inside the app (signed and verified like a remote one).
    public static func bundledManifest() throws -> ModelManifest {
        guard let dir = Bundle.module.url(forResource: "Models", withExtension: nil) else {
            throw ManifestError.unreadable("bundled manifest missing")
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let sig = try String(contentsOf: dir.appendingPathComponent("manifest.json.sig"), encoding: .utf8)
        return try ManifestCodec.load(manifestData: data, signatureBase64: sig)
    }

    public func registerWarmer(runtime: String, _ warmer: @escaping ModelWarmer) {
        warmers[runtime] = warmer
    }

    // MARK: Queries

    public func state(of kind: ModelEntry.Kind) -> ModelState {
        guard let model = manifest.models.first(where: { $0.kind == kind }) else { return .notInstalled }
        return states[model.id] ?? .notInstalled
    }

    /// Folder of the installed, verified version of the model of `kind`, or nil while not ready.
    public func installedDirectory(for kind: ModelEntry.Kind) -> (URL, ModelEntry)? {
        guard let model = manifest.models.first(where: { $0.kind == kind }), states[model.id]?.isReady == true else { return nil }
        return (layout.versionDirectory(model), model)
    }

    /// Overall progress across all models (0...1) and whether anything is still downloading.
    public var overallProgress: (fraction: Double, busy: Bool) {
        var done: Int64 = 0, total: Int64 = 0, busy = false
        for model in manifest.models {
            total += model.totalBytes
            switch states[model.id] {
            case .ready?, .preparing?, .verifying?: done += model.totalBytes
            case .downloading(_, let bytes, _)?: done += bytes; busy = true
            default: break
            }
            if states[model.id]?.isBusy == true { busy = true }
        }
        return (total > 0 ? Double(done) / Double(total) : 0, busy)
    }

    // MARK: Lifecycle

    /// Call at launch: marks valid installs ready (and warms them), installs anything missing, and runs a
    /// throttled update check.
    public func start() {
        for model in manifest.models { ensureInstalled(model) }
        Task { await checkForUpdates(force: false) }
        // Failures that can heal on their own (server hiccup, flaky network, space freed) are retried every 10 minutes.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryFailedInstalls() }
        }
    }

    private func retryFailedInstalls() {
        for model in manifest.models {
            guard case .failed(let failure)? = states[model.id] else { continue }
            switch failure {
            case .offline, .interrupted, .hostUnreachable, .server, .diskFull: ensureInstalled(model)
            default: break // a bad file or a model that won't load needs the user's Try Again / Repair
            }
        }
    }

    /// Installs `model` if needed (no-op while a task for it is already running).
    public func ensureInstalled(_ model: ModelEntry) {
        guard installTasks[model.id] == nil else { return }
        startTask(for: model.id) { [weak self] in await self?.runInstall(model) }
    }

    private func startTask(for modelID: String, _ work: @escaping @MainActor () async -> Void) {
        let token = UUID()
        let previous = installTasks[modelID]?.task
        let removal = pendingRemoval
        installTasks[modelID] = (token, Task { [weak self] in
            // Let a cancelled predecessor finish first, so two tasks never share a staging folder.
            if let previous { previous.cancel(); await previous.value }
            await removal?.value
            await work()
            if self?.installTasks[modelID]?.id == token { self?.installTasks[modelID] = nil }
        })
    }

    /// Re-hashes every installed file; anything missing or corrupt is downloaded again.
    public func repair() {
        for model in manifest.models {
            // Not installed yet: start (or keep) the download; a partial download must survive.
            guard FileManager.default.fileExists(atPath: layout.versionDirectory(model).path) else {
                ensureInstalled(model)
                continue
            }
            startTask(for: model.id) { [weak self] in await self?.repair(model) }
        }
    }

    /// Call when the app quits: saves partial downloads as resume data next to their staging files.
    public func prepareForQuit() {
        let resume = deps.session.suspendAllProducingResumeData()
        for (key, data) in resume {
            // key = "<id>/<version>/<path>"
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3, let model = manifest.models.first(where: { $0.id == parts[0] && $0.version == parts[1] }) else { continue }
            let url = layout.stagingDirectory(model).appendingPathComponent(parts[2]).appendingPathExtension("resume")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if !resume.isEmpty { Log.models.info("saved resume data for \(resume.count, privacy: .public) download(s)") }
    }

    /// Deletes every downloaded model (speech falls back to the system voice until reinstalled).
    public func removeAll() {
        let running = installTasks.values.map(\.task)
        for task in running { task.cancel() }
        installTasks.removeAll()
        deps.session.cancelAll()
        for model in manifest.models { willRemove?(model) }
        for model in manifest.models { states[model.id] = .notInstalled }
        let root = layout.root
        let previous = pendingRemoval
        // Delete only once the cancelled installs have stopped writing into the folder.
        pendingRemoval = Task {
            await previous?.value
            for task in running { await task.value }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            Log.models.info("all models removed")
        }
    }

    /// Returns once a Remove Models in progress has deleted the files (tests; new installs already wait for it).
    public func waitForPendingRemoval() async {
        await pendingRemoval?.value
    }

    /// Fetches the remote manifest (if configured and due), verifies it, and installs newer model versions
    /// side by side before switching over.
    public func checkForUpdates(force: Bool) async {
        let settings = deps.settings()
        guard let urlString = settings.manifestURL, let url = URL(string: urlString), url.scheme == "https" else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard force || now - last > settings.checkIntervalHours * 3600 else { return }
        guard case .allow = deps.policy.evaluate(NetworkIntent(purpose: .modelDownload, host: url.host ?? "", carriesUserContent: false)) else { return }
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let (sigData, sigResponse) = try await URLSession.shared.data(from: url.appendingPathExtension("sig"))
            guard (response as? HTTPURLResponse)?.statusCode == 200, (sigResponse as? HTTPURLResponse)?.statusCode == 200 else { return }
            let remote = try ManifestCodec.load(manifestData: data, signatureBase64: String(decoding: sigData, as: UTF8.self))
            guard ManifestCodec.isNewer(remote.manifestVersion, than: manifest.manifestVersion) else { return }
            try data.write(to: cachedManifestURL, options: .atomic)
            try sigData.write(to: cachedManifestURL.appendingPathExtension("sig"), options: .atomic)
            Log.models.info("newer model manifest \(remote.manifestVersion, privacy: .public); installing side by side")
            let previous = manifest
            manifest = remote
            for model in remote.models where previous.model(id: model.id)?.version != model.version {
                // Keep the old version ready until the new one is verified and warmed (switch-over in runInstall).
                ensureInstalled(model)
            }
        } catch {
            Log.models.error("update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Install

    private func runInstall(_ model: ModelEntry) async {
        // 1. Already installed and intact?
        if isInstalled(model) {
            await warm(model)
            return
        }
        // 2. macOS version gate.
        if let required = OperatingSystemVersion(dotted: model.minMacOS),
           !ProcessInfo.processInfo.isOperatingSystemAtLeast(required) {
            states[model.id] = .failed(.unsupportedMacOS(model.minMacOS))
            return
        }
        let staging = layout.stagingDirectory(model)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // 3. Disk space for what is still missing.
        let missing = model.files.filter { !stagedFileIsValid($0, in: staging) }
        let needed = missing.reduce(0) { $0 + $1.size }
        if needed > 0, let free = deps.availableBytes(layout.root), free < DiskSpace.required(for: needed) {
            states[model.id] = .failed(.diskFull(neededBytes: DiskSpace.required(for: needed), availableBytes: free))
            Log.models.error("\(model.id, privacy: .public): not enough disk space")
            return
        }

        // 4. Fetch every missing file (offline folder → primary URL → mirrors), verifying each one.
        var completed = model.totalBytes - needed
        states[model.id] = .downloading(fraction: Double(completed) / Double(model.totalBytes), bytes: completed, total: model.totalBytes)
        for file in missing {
            if Task.isCancelled { return }
            do {
                try await fetchVerified(file, model: model, into: staging) { [weak self] written in
                    guard let self else { return }
                    let bytes = completed + written
                    self.states[model.id] = .downloading(fraction: Double(bytes) / Double(model.totalBytes), bytes: bytes, total: model.totalBytes)
                }
                completed += file.size
            } catch let failure as ModelFailure {
                states[model.id] = .failed(failure)
                Log.models.error("\(model.id, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
                return
            } catch is CancellationError {
                return
            } catch {
                // Anything else (e.g. a file-system error outside the download itself) is a visible failure with Retry.
                states[model.id] = .failed(ModelFailure.classify(error))
                return
            }
        }

        // 5. Final verification of the whole set, marker, atomic move into place.
        states[model.id] = .verifying
        do {
            try await finalize(model, staging: staging)
        } catch {
            states[model.id] = .failed(.other(String(describing: error)))
            return
        }
        // 6. Warm, then remove versions this one replaces.
        await warm(model)
        removeOtherVersions(of: model)
    }

    private func repair(_ model: ModelEntry) async {
        let dir = layout.versionDirectory(model)
        states[model.id] = .verifying
        var bad: [String] = []
        for file in model.files {
            let url = dir.appendingPathComponent(file.path)
            let hash = try? await Task.detached { try SHA256Hex.file(at: url) }.value
            if hash != file.sha256 { bad.append(file.path) }
        }
        if bad.isEmpty, FileManager.default.fileExists(atPath: layout.marker(model).path) {
            Log.models.info("\(model.id, privacy: .public): repair found no problems")
            states[model.id] = .ready(version: model.version)
            return
        }
        Log.models.notice("\(model.id, privacy: .public): repair re-fetching \(bad.count, privacy: .public) file(s)")
        willRemove?(model)
        // Move the good files back to staging so only the bad ones are downloaded again.
        let staging = layout.stagingDirectory(model)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: layout.marker(model))
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.moveItem(at: dir, to: staging)
        }
        for file in model.files {
            let url = staging.appendingPathComponent(file.path)
            if bad.contains(file.path) {
                try? FileManager.default.removeItem(at: url)
            } else {
                // Just re-hashed and correct: stamp as verified so only the bad files are fetched again.
                try? file.sha256.write(to: url.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
            }
        }
        states[model.id] = .notInstalled
        await runInstall(model)
    }

    private func isInstalled(_ model: ModelEntry) -> Bool {
        let markerURL = layout.marker(model)
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(InstallMarker.self, from: data),
              marker.matches(model) else { return false }
        // Cheap integrity check on every launch: presence and size. Full re-hash is the Repair action.
        let dir = layout.versionDirectory(model)
        return model.files.allSatisfy { file in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    private func stagedFileIsValid(_ file: ModelFile, in staging: URL) -> Bool {
        let url = staging.appendingPathComponent(file.path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.int64Value == file.size else { return false }
        // Staged files were verified before being placed; a matching ".ok" stamp proves that.
        return (try? String(contentsOf: url.appendingPathExtension("ok"), encoding: .utf8)) == file.sha256
    }

    /// Fetches one file to `staging/<path>`, trying the offline folder, then each URL with retries/backoff,
    /// and only keeps it when its SHA-256 matches. Throws `ModelFailure` when every option is exhausted.
    private func fetchVerified(_ file: ModelFile, model: ModelEntry, into staging: URL,
                               progress: @escaping @MainActor (Int64) -> Void) async throws {
        let destination = staging.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings = deps.settings()

        // Pre-provisioned offline folder (company edition, air-gapped Macs).
        if let offline = FileSources.offlineCandidate(for: file, model: model, folder: settings.offlineFolder),
           FileManager.default.fileExists(atPath: offline.path) {
            let tmp = staging.appendingPathComponent(".\(UUID().uuidString)")
            try? FileManager.default.copyItem(at: offline, to: tmp)
            if (try? SHA256Hex.file(at: tmp)) == file.sha256 {
                try place(tmp, at: destination, file: file)
                progress(file.size)
                return
            }
            try? FileManager.default.removeItem(at: tmp)
            Log.models.notice("offline copy of \(file.path, privacy: .public) did not verify; downloading instead")
        }

        let sources = FileSources.candidates(for: file, model: model, mirrors: settings.mirrorBaseURLs)
        let resumeURL = destination.appendingPathExtension("resume")
        var lastFailure: ModelFailure = .other("no source")
        var attempt = 0
        var hashFailures = 0
        while attempt < deps.maxAttempts {
            try Task.checkCancellation()
            let source = sources[min(attempt / 2, sources.count - 1) % max(sources.count, 1)] // two tries per source
            attempt += 1
            if case .deny(let message) = deps.policy.evaluate(NetworkIntent(purpose: .modelDownload, host: source.host ?? "", carriesUserContent: false)) {
                throw ModelFailure.blockedByPolicy(message)
            }
            if !networkAvailable {
                await waitForNetwork()
                try Task.checkCancellation() // removed or repaired while offline: don't come back from the dead
            }
            // Resume data only applies to the host that produced it; mirrors start fresh.
            let resumeData = source == sources.first ? try? Data(contentsOf: resumeURL) : nil
            do {
                let key = "\(model.id)/\(model.version)/\(file.path)"
                let downloaded = try await deps.session.fetch(source, key: key, resumeData: resumeData) { written, _ in
                    Task { @MainActor in progress(written) }
                }
                try? FileManager.default.removeItem(at: resumeURL)
                let hash = try await Task.detached { try SHA256Hex.file(at: downloaded) }.value
                guard hash == file.sha256 else {
                    try? FileManager.default.removeItem(at: downloaded)
                    hashFailures += 1
                    lastFailure = .hashMismatch(file.path)
                    Log.models.error("hash mismatch for \(file.path, privacy: .public) from \(source.host ?? "?", privacy: .public)")
                    if hashFailures >= 2 { throw lastFailure } // the source itself is serving different bytes
                    continue
                }
                do {
                    try place(downloaded, at: destination, file: file)
                } catch {
                    throw ModelFailure.classify(error) // disk full or unwritable: downloading again won't help
                }
                return
            } catch let error as DownloadError {
                lastFailure = error.failure
                if let data = error.resumeData {
                    try? data.write(to: resumeURL, options: .atomic)
                } else {
                    // Stale or rejected resume data must not poison every later attempt.
                    try? FileManager.default.removeItem(at: resumeURL)
                }
                if case .hostBlocked = error.failure, attempt >= sources.count * 2 { throw error.failure }
                Log.models.notice("download attempt \(attempt, privacy: .public) for \(file.path, privacy: .public) failed: \(String(describing: error.failure), privacy: .public)")
                await deps.sleep(deps.backoff.delay(attempt: attempt))
            } catch let failure as ModelFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = ModelFailure.classify(error)
                await deps.sleep(deps.backoff.delay(attempt: attempt))
            }
        }
        throw lastFailure
    }

    /// Moves a verified file into staging and stamps it as verified.
    private func place(_ source: URL, at destination: URL, file: ModelFile) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        try file.sha256.write(to: destination.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
    }

    /// Re-checks sizes, writes the marker inside staging, then renames staging → final in one step.
    private func finalize(_ model: ModelEntry, staging: URL) async throws {
        var verified: [String: String] = [:]
        for file in model.files {
            let url = staging.appendingPathComponent(file.path)
            let stamp = try? String(contentsOf: url.appendingPathExtension("ok"), encoding: .utf8)
            guard stamp == file.sha256 else { throw ModelFailure.hashMismatch(file.path) }
            try? FileManager.default.removeItem(at: url.appendingPathExtension("ok"))
            verified[file.path] = file.sha256
        }
        // Drop leftovers that are not part of the model (resume data, temp files).
        Self.removeLeftovers(in: staging)
        let marker = InstallMarker(modelID: model.id, version: model.version, manifestVersion: manifest.manifestVersion,
                                   files: verified, installedAt: Date())
        try JSONEncoder().encode(marker).write(to: staging.appendingPathComponent(InstallMarker.fileName), options: .atomic)
        let final = layout.versionDirectory(model)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final) // stale partial install of the same version
        }
        try FileManager.default.moveItem(at: staging, to: final)
        // Remove now-empty staging parents (".staging/<id>", ".staging").
        for dir in [staging.deletingLastPathComponent(), staging.deletingLastPathComponent().deletingLastPathComponent()] {
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        Log.models.info("\(model.id, privacy: .public) \(model.version, privacy: .public) installed")
    }

    private nonisolated static func removeLeftovers(in staging: URL) {
        guard let items = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return }
        for url in items where url.pathExtension == "resume" || url.lastPathComponent.hasPrefix(".") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func warm(_ model: ModelEntry) async {
        states[model.id] = .preparing
        if let warmer = warmers[model.runtime] {
            let dir = layout.versionDirectory(model)
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try await warmer(dir, model)
                Log.models.info("\(model.id, privacy: .public) warmed in \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000), privacy: .public) ms")
            } catch {
                Log.models.error("\(model.id, privacy: .public) warm-up failed: \(String(describing: error), privacy: .public)")
                // Files verified but the runtime can't load them: offer Repair rather than claiming Ready.
                states[model.id] = .failed(.other("load failed"))
                return
            }
        }
        states[model.id] = .ready(version: model.version)
    }

    private func removeOtherVersions(of model: ModelEntry) {
        for version in layout.installedVersions(of: model.id) where version != model.version {
            let old = layout.root.appendingPathComponent(model.id).appendingPathComponent(version)
            try? FileManager.default.removeItem(at: old)
            Log.models.info("\(model.id, privacy: .public): removed old version \(version, privacy: .public)")
        }
    }

    // MARK: Network

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available) }
        }
        monitor.start(queue: DispatchQueue(label: "com.zakvirani.wisp.models.network"))
        pathMonitor = monitor
    }

    private func networkChanged(_ available: Bool) {
        networkAvailable = available
        isOffline = !available
        guard available else { return }
        // Retry anything that failed for network reasons as soon as we're back online.
        for model in manifest.models {
            if case .failed(let failure)? = states[model.id], failure.isRetryable, !(failure == .hashMismatch("")) {
                switch failure {
                case .offline, .interrupted, .hostUnreachable, .server: ensureInstalled(model)
                default: break
                }
            }
        }
    }

    private func waitForNetwork() async {
        guard !networkAvailable else { return }
        // Wake every 2 s to notice cancellation; resume as soon as the network is back.
        while !networkAvailable && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static func loadCachedManifest(at url: URL) -> ModelManifest? {
        guard let data = try? Data(contentsOf: url),
              let sig = try? String(contentsOf: url.appendingPathExtension("sig"), encoding: .utf8) else { return nil }
        return try? ManifestCodec.load(manifestData: data, signatureBase64: sig)
    }
}

extension OperatingSystemVersion {
    init?(dotted: String) {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.init(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
    }
}
