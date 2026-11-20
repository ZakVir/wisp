import XCTest
@testable import WispCore

final class VoiceCommandTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(VoiceCommand.parse("talk faster"), .faster)
        XCTAssertEqual(VoiceCommand.parse("Can you speak a little slower please?"), .slower)
        XCTAssertEqual(VoiceCommand.parse("slow down"), .slower)
        XCTAssertEqual(VoiceCommand.parse("normal speed"), .normalSpeed)
        XCTAssertEqual(VoiceCommand.parse("captions only"), .mute)
        XCTAssertEqual(VoiceCommand.parse("be quiet"), .hush, "just stop, don't change settings")
        XCTAssertEqual(VoiceCommand.parse("Stop it."), .hush)
        XCTAssertEqual(VoiceCommand.parse("never mind"), .hush)
        XCTAssertNil(VoiceCommand.parse("stop the video"))
        XCTAssertEqual(VoiceCommand.parse("turn your voice back on"), .unmute)
        XCTAssertNil(VoiceCommand.parse("how do I make the video play faster"))
        XCTAssertNil(VoiceCommand.parse("why is my computer slow"))
    }

    func testRates() {
        XCTAssertEqual(VoiceCommand.faster.rate(from: 1.0), 1.15, accuracy: 0.001)
        XCTAssertEqual(VoiceCommand.slower.rate(from: 0.6), 0.5, accuracy: 0.001)
        XCTAssertEqual(VoiceCommand.faster.rate(from: 1.95), 2.0, accuracy: 0.001)
        XCTAssertEqual(VoiceCommand.normalSpeed.rate(from: 1.6), 1.0)
    }
}
