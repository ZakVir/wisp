import CryptoKit
import XCTest
@testable import WispCore

final class ModelManifestTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var trusted: [String] { [key.publicKey.rawRepresentation.base64EncodedString()] }

    private func sample(files: [ModelFile]? = nil, id: String = "moonshine-small-streaming-en", version: String = "q1") -> ModelManifest {
        ModelManifest(manifestVersion: "2026.10.01.1", models: [
            ModelEntry(id: id, version: version, kind: .speechToText, displayName: "Moonshine", runtime: "moonshine-ort",
                       license: "MIT", licenseURL: "https://example.com/LICENSE", minMacOS: "15.0",
                       files: files ?? [ModelFile(path: "encoder.ort", url: "https://example.com/encoder.ort", size: 10,
                                                  sha256: String(repeating: "a", count: 64))]),
        ])
    }

    private func signed(_ manifest: ModelManifest) throws -> (Data, String) {
        let data = try JSONEncoder().encode(manifest)
        return (data, try key.signature(for: data).base64EncodedString())
    }

    func testValidSignedManifestLoads() throws {
        let (data, sig) = try signed(sample())
        let m = try ManifestCodec.load(manifestData: data, signatureBase64: sig, trustedKeys: trusted)
        XCTAssertEqual(m.models.first?.id, "moonshine-small-streaming-en")
        XCTAssertEqual(m.models.first?.totalBytes, 10)
    }

    func testTamperedBytesFailSignature() throws {
        var (data, sig) = try signed(sample())
        data[data.count / 2] ^= 0x01
        XCTAssertThrowsError(try ManifestCodec.load(manifestData: data, signatureBase64: sig, trustedKeys: trusted)) {
            XCTAssertEqual($0 as? ManifestError, .badSignature)
        }
    }

    func testWrongKeyFailsSignature() throws {
        let (data, sig) = try signed(sample())
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try ManifestCodec.load(manifestData: data, signatureBase64: sig, trustedKeys: [other]))
        XCTAssertThrowsError(try ManifestCodec.load(manifestData: data, signatureBase64: "not base64!!", trustedKeys: trusted))
    }

    func testRejectsPathTraversalAndAbsolutePaths() throws {
        for bad in ["../etc/passwd", "/etc/passwd", "a/../../b", "a//b", ""] {
            let m = sample(files: [ModelFile(path: bad, url: "https://example.com/x", size: 1, sha256: String(repeating: "a", count: 64))])
            XCTAssertThrowsError(try ManifestCodec.parse(JSONEncoder().encode(m)), "path \(bad)")
        }
        XCTAssertThrowsError(try ManifestCodec.parse(JSONEncoder().encode(sample(id: ".."))))
    }

    func testRejectsHttpBadHashesDuplicatesAndSchema() throws {
        let http = sample(files: [ModelFile(path: "a", url: "http://example.com/a", size: 1, sha256: String(repeating: "a", count: 64))])
        XCTAssertThrowsError(try ManifestCodec.parse(JSONEncoder().encode(http)))
        let shortHash = sample(files: [ModelFile(path: "a", url: "https://example.com/a", size: 1, sha256: "abc")])
        XCTAssertThrowsError(try ManifestCodec.parse(JSONEncoder().encode(shortHash)))
        let upper = sample(files: [ModelFile(path: "a", url: "https://example.com/a", size: 1, sha256: String(repeating: "A", count: 64))])
        XCTAssertThrowsError(try ManifestCodec.parse(JSONEncoder().encode(upper)))
        let f = ModelFile(path: "a", url: "https://example.com/a", size: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try ManifestCodec.parse(JSONEncoder().encode(sample(files: [f, f]))))
        var schema = sample()
        schema.schema = 99
        XCTAssertThrowsError(try ManifestCodec.parse(JSONEncoder().encode(schema))) {
            XCTAssertEqual($0 as? ManifestError, .unsupportedSchema(99))
        }
        XCTAssertThrowsError(try ManifestCodec.parse(Data("{not json".utf8)))
    }

    func testVersionComparison() {
        XCTAssertTrue(ManifestCodec.isNewer("2026.10.01.2", than: "2026.10.01.1"))
        XCTAssertTrue(ManifestCodec.isNewer("2026.11.01", than: "2026.10.30.9"))
        XCTAssertFalse(ManifestCodec.isNewer("2026.10.01.1", than: "2026.10.01.1"))
        XCTAssertFalse(ManifestCodec.isNewer("2026.9.30", than: "2026.10.01"))
    }

    func testBundledManifestIsSignedByTheShippedKey() throws {
        // The manifest shipped in the app must verify with the embedded public key.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WispMac/Resources/Models")
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let sig = try String(contentsOf: dir.appendingPathComponent("manifest.json.sig"), encoding: .utf8)
        let m = try ManifestCodec.load(manifestData: data, signatureBase64: sig)
        XCTAssertEqual(Set(m.models.map(\.kind)), [.speechToText, .textToSpeech])
        let total = m.models.reduce(0) { $0 + $1.totalBytes }
        XCTAssertLessThan(total, 700 * 1024 * 1024, "model footprint must stay under 700 MB")
    }
}

final class ModelInstallModelTests: XCTestCase {
    func testMarkerMatchesOnlyExactPins() {
        let file = ModelFile(path: "a", url: "https://x/a", size: 1, sha256: String(repeating: "b", count: 64))
        let model = ModelEntry(id: "m", version: "1", kind: .textToSpeech, displayName: "M", runtime: "r", license: "MIT",
                               licenseURL: "https://x", minMacOS: "15.0", files: [file])
        let good = InstallMarker(modelID: "m", version: "1", manifestVersion: "1", files: ["a": file.sha256], installedAt: Date())
        XCTAssertTrue(good.matches(model))
        var stale = good
        stale.files["a"] = String(repeating: "c", count: 64)
        XCTAssertFalse(stale.matches(model))
        var otherVersion = good
        otherVersion.version = "0"
        XCTAssertFalse(otherVersion.matches(model))
    }

    func testBackoffGrowsAndCaps() {
        let b = Backoff(base: 2, cap: 60, jitter: 0)
        XCTAssertEqual(b.delay(attempt: 1, random: 0.5), 2)
        XCTAssertEqual(b.delay(attempt: 3, random: 0.5), 8)
        XCTAssertEqual(b.delay(attempt: 20, random: 0.5), 60)
        let j = Backoff(base: 10, cap: 100, jitter: 0.2)
        XCTAssertEqual(j.delay(attempt: 1, random: 0), 8, accuracy: 1e-9)
        XCTAssertEqual(j.delay(attempt: 1, random: 1), 12, accuracy: 1e-9)
    }

    func testFailureClassification() {
        XCTAssertEqual(ModelFailure.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ModelFailure.classify(URLError(.networkConnectionLost)), .interrupted)
        if case .hostBlocked = ModelFailure.classify(URLError(.serverCertificateUntrusted)) {} else { XCTFail() }
        if case .hostUnreachable = ModelFailure.classify(URLError(.cannotFindHost)) {} else { XCTFail() }
        if case .diskFull = ModelFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) {} else { XCTFail() }
        XCTAssertEqual(ModelFailure.classify(httpStatus: 403), .hostBlocked("HTTP 403"))
        XCTAssertEqual(ModelFailure.classify(httpStatus: 503), .server(503))
        XCTAssertFalse(ModelFailure.manifestRejected("x").isRetryable)
        XCTAssertTrue(ModelFailure.offline.isRetryable)
        XCTAssertTrue(ModelFailure.diskFull(neededBytes: 1_000_000_000, availableBytes: 10).userMessage.contains("Not enough space"))
    }

    func testMirrorAndOfflineCandidates() {
        let file = ModelFile(path: "w/weight.bin", url: "https://hf.co/a/b", size: 1, sha256: String(repeating: "b", count: 64))
        let model = ModelEntry(id: "kokoro", version: "v1", kind: .textToSpeech, displayName: "K", runtime: "r", license: "A",
                               licenseURL: "https://x", minMacOS: "15.0", files: [file])
        let urls = FileSources.candidates(for: file, model: model, mirrors: ["https://cdn.example.com/models/", "http://insecure.example.com"])
        XCTAssertEqual(urls.map(\.absoluteString), ["https://hf.co/a/b", "https://cdn.example.com/models/kokoro/v1/w/weight.bin"],
                       "primary first, https mirrors only")
        XCTAssertEqual(FileSources.offlineCandidate(for: file, model: model, folder: "/Volumes/Kit")?.path,
                       "/Volumes/Kit/kokoro/v1/w/weight.bin")
        XCTAssertNil(FileSources.offlineCandidate(for: file, model: model, folder: nil))
    }

    func testDiskSpaceRequirement() {
        XCTAssertEqual(DiskSpace.required(for: 1000), 1000 + 100 + DiskSpace.margin)
        XCTAssertNotNil(DiskSpace.available(at: FileManager.default.temporaryDirectory))
    }
}
