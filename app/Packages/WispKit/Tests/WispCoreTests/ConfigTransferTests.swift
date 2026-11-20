import XCTest
@testable import WispCore

final class ConfigTransferTests: XCTestCase {
    func testRoundTripKeepsLocalSetup() throws {
        var a = AppConfig()
        a.vision.instructions = "I'm new to Macs."
        a.speech.captionSize = "large"
        a.privacy.privateApps = ["com.1password.1password"]
        a.onboardingCompleted = true
        let data = try ConfigTransfer.exportData(a)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("onboardingCompleted"))
        var b = AppConfig()
        b.onboardingCompleted = false
        let imported = try ConfigTransfer.importing(data, over: b)
        XCTAssertEqual(imported.vision.instructions, "I'm new to Macs.")
        XCTAssertEqual(imported.speech.captionSize, "large")
        XCTAssertEqual(imported.privacy.privateApps, ["com.1password.1password"])
        XCTAssertFalse(imported.onboardingCompleted, "setup progress stays this Mac's")
    }

    func testPartialFilesAndJunk() throws {
        let partial = Data(#"{"speech": {"captionSize": "small"}}"#.utf8)
        var current = AppConfig()
        current.vision.answerLength = "short"
        let merged = try ConfigTransfer.importing(partial, over: current)
        XCTAssertEqual(merged.speech.captionSize, "small")
        XCTAssertEqual(merged.vision.answerLength, "short")
        XCTAssertThrowsError(try ConfigTransfer.importing(Data("hello".utf8), over: current))
        XCTAssertThrowsError(try ConfigTransfer.importing(Data(#"{"name": "x"}"#.utf8), over: current))
    }
}
