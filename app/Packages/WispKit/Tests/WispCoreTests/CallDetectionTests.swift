import XCTest
@testable import WispCore

final class CallDetectionTests: XCTestCase {
    func testSystemListenersAreNotCalls() {
        for id in ["com.apple.CoreSpeech", "com.apple.siri.embeddedspeech", "com.apple.assistantd", "com.apple.DictationIM"] {
            XCTAssertFalse(CallDetection.countsAsCall(bundleID: id), id)
        }
    }

    func testCallAppsAndUnknownProcessesCount() {
        for id in ["us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2", "com.google.Chrome.helper", "com.apple.WebKit.GPU", "com.hnc.Discord"] {
            XCTAssertTrue(CallDetection.countsAsCall(bundleID: id), id)
        }
        XCTAssertTrue(CallDetection.countsAsCall(bundleID: nil))
    }
}
