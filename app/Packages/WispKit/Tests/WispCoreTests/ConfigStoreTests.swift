import XCTest
@testable import WispCore

final class ConfigStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(managed: String? = nil) throws -> ConfigStore {
        let managedURL = dir.appendingPathComponent("managed.json")
        if let managed { try managed.write(to: managedURL, atomically: true, encoding: .utf8) }
        return ConfigStore(userFileURL: dir.appendingPathComponent("settings.json"), managedFileURL: managedURL)
    }

    func testDefaultsWhenNoFiles() throws {
        let s = try store()
        XCTAssertEqual(s.config, AppConfig())
        XCTAssertTrue(s.lockedKeyPaths.isEmpty)
    }

    func testUserChangePersistsOnlyTheDiff() throws {
        let s = try store()
        try s.update { $0.vision.modelID = "z-ai/glm-5.3-flash" }
        let saved = try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("glm-5.3-flash"))
        XCTAssertFalse(saved.contains("baseURL"), "unchanged defaults must not be written")
        let reopened = try store()
        XCTAssertEqual(reopened.config.vision.modelID, "z-ai/glm-5.3-flash")
    }

    func testManagedKeysWinAndAreLocked() throws {
        let s = try store(managed: #"{"vision": {"modelID": "meta/llama-3.2-90b-vision-instruct"}}"#)
        XCTAssertEqual(s.config.vision.modelID, "meta/llama-3.2-90b-vision-instruct")
        XCTAssertTrue(s.isLocked("vision.modelID"))
        XCTAssertTrue(s.isLocked("vision"), "a parent of a locked key reports locked")
        XCTAssertFalse(s.isLocked("vision.baseURL"))
        try s.update { $0.vision.modelID = "stepfun-ai/step-5-preview"; $0.vision.timeoutSeconds = 9 }
        XCTAssertEqual(s.config.vision.modelID, "meta/llama-3.2-90b-vision-instruct", "user cannot override a managed key")
        XCTAssertEqual(s.config.vision.timeoutSeconds, 9, "unmanaged sibling keys still change")
    }

    func testRetiredModelInSavedSettingsIsReplaced() throws {
        let s = try store()
        try s.update { $0.vision.modelID = "moonshotai/kimi-k3"
            $0.vision.fallbackModelIDs = ["moonshotai/kimi-k3", "nvidia/nemotron-3.5-super-vl-120b-a12b", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"] }
        let reloaded = try store().config.vision
        XCTAssertEqual(reloaded.modelID, "nvidia/nemotron-3.5-super-vl-120b-a12b")
        XCTAssertEqual(reloaded.fallbackModelIDs, ["nvidia/nemotron-3.5-super-vl-120b-a12b", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"])
    }

    func testClearingAnOptionalOverridesLowerLayer() throws {
        let s = try store()
        try s.update { $0.models.manifestURL = "https://cdn.example.com/manifest.json" }
        XCTAssertEqual(try store().config.models.manifestURL, "https://cdn.example.com/manifest.json")
        try s.update { $0.models.manifestURL = nil }
        XCTAssertNil(try store().config.models.manifestURL)
    }

    func testCorruptUserFileFallsBackToDefaults() throws {
        try "{not json".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let s = try store()
        XCTAssertEqual(s.config, AppConfig())
        XCTAssertFalse(s.loadWarnings.isEmpty)
    }

    func testWrongTypeInUserFileIsIgnoredNotFatal() throws {
        try #"{"vision": {"timeoutSeconds": "fast"}}"#.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let s = try store(managed: #"{"speech": {"rate": 1.25}}"#)
        XCTAssertEqual(s.config.vision.timeoutSeconds, AppConfig().vision.timeoutSeconds)
        XCTAssertEqual(s.config.speech.rate, 1.25, "managed values survive a bad user layer")
    }

    func testOneBadValueDoesNotBlockOtherSettingsOrSaving() throws {
        try #"{"vision": {"timeoutSeconds": "fast"}, "speech": {"showCaptions": false}}"#
            .write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let s = try store()
        XCTAssertFalse(s.config.speech.showCaptions, "valid sibling settings are kept")
        XCTAssertEqual(s.config.vision.timeoutSeconds, AppConfig().vision.timeoutSeconds)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json.bak").path))
        try s.update { $0.speech.rate = 1.5 }
        XCTAssertEqual(s.config.speech.rate, 1.5, "saving works after sanitizing")
        XCTAssertEqual(try store().config.speech.rate, 1.5)
    }

    func testBrokenManagedFileNeverTouchesUserSettings() throws {
        let userURL = dir.appendingPathComponent("settings.json")
        try #"{"speech": {"showCaptions": false}}"#.write(to: userURL, atomically: true, encoding: .utf8)
        let s = try store(managed: #"{"vision": {"timeoutSeconds": "fast"}}"#)
        XCTAssertFalse(s.config.speech.showCaptions, "user settings still apply")
        XCTAssertEqual(try String(contentsOf: userURL, encoding: .utf8), #"{"speech": {"showCaptions": false}}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userURL.appendingPathExtension("bak").path))
        XCTAssertTrue(s.loadWarnings.contains { $0.contains("managed config") })
    }

    func testUnreadableManagedFileWarns() throws {
        let managedURL = dir.appendingPathComponent("managed.json")
        try "{}".write(to: managedURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: managedURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: managedURL.path) }
        let s = ConfigStore(userFileURL: dir.appendingPathComponent("settings.json"), managedFileURL: managedURL)
        XCTAssertTrue(s.loadWarnings.contains { $0.contains("cannot be read") })
    }

    func testProviderDisplayName() {
        var v = VisionSettings()
        XCTAssertEqual(v.providerDisplayName, "NVIDIA")
        v.baseURL = "https://api.anthropic.com/v1"
        XCTAssertEqual(v.providerDisplayName, "Anthropic")
        v.baseURL = "http://localhost:1234/v1"
        XCTAssertEqual(v.providerDisplayName, "a local server on this Mac")
    }

    func testResetUserSettingsKeepsManaged() throws {
        let s = try store(managed: #"{"speech": {"voiceID": "bf_emma"}}"#)
        try s.update { $0.speech.rate = 1.5 }
        try s.resetUserSettings()
        XCTAssertEqual(s.config.speech.rate, 1.0)
        XCTAssertEqual(s.config.speech.voiceID, "bf_emma")
    }

    func testMergeIsDeep() {
        let merged = ConfigStore.merge(["a": ["b": 1, "c": 2]], ["a": ["c": 3]])
        XCTAssertEqual((merged["a"] as? [String: Int])?["b"], 1)
        XCTAssertEqual((merged["a"] as? [String: Int])?["c"], 3)
    }
}
