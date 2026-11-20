import CryptoKit
import XCTest
@testable import WispCore
@testable import WispMac

/// End-to-end installer tests against a local HTTP server with fault injection (tools/test_http_server.py).
@MainActor
final class ModelManagerTests: XCTestCase {
    private var serverRoot: URL!
    private var modelsRoot: URL!
    private var server: Process!
    private var port = 0

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-mm-\(UUID().uuidString)")
        serverRoot = base.appendingPathComponent("server")
        modelsRoot = base.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: serverRoot.appendingPathComponent(".faults"), withIntermediateDirectories: true)
        let portFile = base.appendingPathComponent("port")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/test_http_server.py")
        server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, serverRoot.path, portFile.path]
        try server.run()
        for _ in 0..<100 {
            if let s = try? String(contentsOf: portFile, encoding: .utf8), let p = Int(s) { port = p; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(port, 0, "test server did not start")
    }

    override func tearDown() async throws {
        server?.terminate()
        try? FileManager.default.removeItem(at: serverRoot.deletingLastPathComponent())
    }

    // MARK: Helpers

    /// Writes random content for each (path, size) to the server and returns a model pinning their hashes.
    private func makeModel(_ files: [(String, Int)], id: String = "test-model", version: String = "1") throws -> ModelEntry {
        var pinned: [ModelFile] = []
        for (path, size) in files {
            var bytes = [UInt8](repeating: 0, count: size)
            for i in 0..<size { bytes[i] = UInt8((i * 31 + size) & 0xFF) }
            let data = Data(bytes)
            let url = serverRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            pinned.append(ModelFile(path: path, url: "http://127.0.0.1:\(port)/\(path)", size: Int64(size), sha256: SHA256Hex.data(data)))
        }
        return ModelEntry(id: id, version: version, kind: .speechToText, displayName: "Test", runtime: "test",
                          license: "MIT", licenseURL: "https://example.com", minMacOS: "15.0", files: pinned)
    }

    private func fault(_ path: String, _ value: String) throws {
        try value.write(to: serverRoot.appendingPathComponent(".faults").appendingPathComponent(path.replacingOccurrences(of: "/", with: "__")),
                        atomically: true, encoding: .utf8)
    }

    private func manager(_ model: ModelEntry, free: Int64? = nil, maxAttempts: Int = 4,
                         policy: PolicyGate = ConsentPolicyGate(disclosureAccepted: { true })) -> ModelManager {
        let session = DownloadSession(configuration: .ephemeral, holdingDirectory: modelsRoot.appendingPathComponent(".hold"))
        let deps = ModelManager.Dependencies(root: modelsRoot, session: session, policy: policy, settings: { ModelSourceSettings() },
                                             availableBytes: { _ in free ?? 1 << 40 }, backoff: Backoff(base: 0.01, cap: 0.05, jitter: 0),
                                             maxAttempts: maxAttempts, sleep: { try? await Task.sleep(for: .seconds($0)) })
        return ModelManager(manifest: ModelManifest(manifestVersion: "1", models: [model]), dependencies: deps)
    }

    private func waitForSettled(_ mm: ModelManager, _ id: String, timeout: Double = 20) async -> ModelState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = mm.states[id] ?? .notInstalled
            switch s {
            case .ready, .failed: return s
            default: try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return mm.states[id] ?? .notInstalled
    }

    private func requests() -> [String] {
        ((try? String(contentsOf: serverRoot.appendingPathComponent(".requests.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: Tests

    func testInstallsVerifiesAndWritesMarkerAtomically() async throws {
        let model = try makeModel([("a.bin", 200_000), ("dir/b.bin", 50_000)])
        let mm = manager(model)
        var warmed = false
        mm.registerWarmer(runtime: "test") { _, _ in await MainActor.run { warmed = true } }
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        XCTAssertEqual(state, .ready(version: "1"))
        XCTAssertTrue(warmed, "warm-up runs after install")
        let dir = mm.layout.versionDirectory(model)
        XCTAssertEqual(try SHA256Hex.file(at: dir.appendingPathComponent("dir/b.bin")), model.files[1].sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mm.layout.marker(model).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mm.layout.stagingDirectory(model).path), "staging renamed away")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bin.ok").path), "no stamps left behind")

        // A second manager (next launch) sees the install without downloading again.
        let before = requests().count
        let again = manager(model)
        again.ensureInstalled(model)
        let state2 = await waitForSettled(again, model.id)
        XCTAssertEqual(state2, .ready(version: "1"))
        XCTAssertEqual(requests().count, before, "no network on a valid install")
    }

    func testResumesAfterInterruptedDownload() async throws {
        let model = try makeModel([("big.bin", 3_000_000)])
        try fault("big.bin", "drop:1000000")
        let mm = manager(model)
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        XCTAssertEqual(state, .ready(version: "1"))
        let log = requests().filter { $0.hasPrefix("big.bin") }
        XCTAssertGreaterThanOrEqual(log.count, 2, "retried after the drop")
        XCTAssertTrue(log.dropFirst().contains { $0.contains("bytes=") }, "second request resumed with a Range header: \(log)")
    }

    func testHashMismatchNeverInstalls() async throws {
        let model = try makeModel([("x.bin", 10_000)])
        try fault("x.bin", "corrupt")
        let mm = manager(model)
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        XCTAssertEqual(state, .failed(.hashMismatch("x.bin")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mm.layout.versionDirectory(model).path), "nothing unverified is installed")
    }

    func testRepairRefetchesOnlyCorruptFiles() async throws {
        let model = try makeModel([("good.bin", 40_000), ("bad.bin", 40_000)])
        let mm = manager(model)
        mm.ensureInstalled(model)
        _ = await waitForSettled(mm, model.id)
        // Corrupt one installed file in place.
        let bad = mm.layout.versionDirectory(model).appendingPathComponent("bad.bin")
        var data = try Data(contentsOf: bad)
        data[100] ^= 0xFF
        try data.write(to: bad)
        let before = requests()
        mm.repair()
        try await Task.sleep(for: .milliseconds(200))
        let state = await waitForSettled(mm, model.id)
        XCTAssertEqual(state, .ready(version: "1"))
        XCTAssertEqual(try SHA256Hex.file(at: bad), model.files[1].sha256)
        let new = requests().dropFirst(before.count)
        XCTAssertTrue(new.allSatisfy { $0.hasPrefix("bad.bin") }, "only the corrupt file was downloaded again: \(Array(new))")
    }

    func testHostBlockedFailsWithPlainMessage() async throws {
        let model = try makeModel([("f.bin", 1000)])
        try fault("f.bin", "status:403")
        let mm = manager(model, maxAttempts: 2)
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        guard case .failed(let failure) = state, case .hostBlocked = failure else { return XCTFail("got \(state)") }
        XCTAssertTrue(failure.userMessage.contains("blocking"), failure.userMessage)
    }

    func testServerErrorRetriesThenReports() async throws {
        let model = try makeModel([("s.bin", 1000)])
        try fault("s.bin", "status:503")
        let mm = manager(model, maxAttempts: 3)
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        XCTAssertEqual(state, .failed(.server(503)))
        XCTAssertEqual(requests().filter { $0.hasPrefix("s.bin") }.count, 3, "retried with backoff")
    }

    func testDiskFullIsReportedBeforeDownloading() async throws {
        let model = try makeModel([("d.bin", 5000)])
        let mm = manager(model, free: 1000)
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        guard case .failed(.diskFull) = state else { return XCTFail("got \(state)") }
        XCTAssertTrue(requests().isEmpty, "no download attempted")
    }

    func testUnreachableHostIsRetryableFailure() async throws {
        var model = try makeModel([("u.bin", 1000)])
        model.files[0].url = "http://127.0.0.1:9/u.bin" // discard port: connection refused
        let mm = manager(model, maxAttempts: 2)
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        guard case .failed(let failure) = state else { return XCTFail("got \(state)") }
        XCTAssertTrue(failure.isRetryable)
    }

    func testPolicyDenialStopsBeforeNetwork() async throws {
        struct Deny: PolicyGate { func evaluate(_ intent: NetworkIntent) -> PolicyDecision { .deny(userMessage: "Blocked by policy") } }
        let model = try makeModel([("p.bin", 1000)])
        let mm = manager(model, policy: Deny())
        mm.ensureInstalled(model)
        let state = await waitForSettled(mm, model.id)
        XCTAssertEqual(state, .failed(.blockedByPolicy("Blocked by policy")))
        XCTAssertTrue(requests().isEmpty)
    }

    func testRemoveAllDeletesEverything() async throws {
        let model = try makeModel([("r.bin", 1000)])
        let mm = manager(model)
        mm.ensureInstalled(model)
        _ = await waitForSettled(mm, model.id)
        mm.removeAll()
        XCTAssertEqual(mm.states[model.id], .notInstalled)
        await mm.waitForPendingRemoval() // files go once cancelled installs have stopped
        XCTAssertFalse(FileManager.default.fileExists(atPath: mm.layout.versionDirectory(model).path))
    }

    func testNewVersionInstallsSideBySideThenOldIsRemoved() async throws {
        let v1 = try makeModel([("m.bin", 2000)], version: "1")
        let mm = manager(v1)
        mm.ensureInstalled(v1)
        _ = await waitForSettled(mm, v1.id)
        let v2 = try makeModel([("m2.bin", 3000)], version: "2")
        mm.ensureInstalled(v2)
        try await Task.sleep(for: .milliseconds(100))
        let state = await waitForSettled(mm, v2.id)
        XCTAssertEqual(state, .ready(version: "2"))
        XCTAssertEqual(mm.layout.installedVersions(of: v2.id), ["2"], "old version removed after switch-over")
    }
}
