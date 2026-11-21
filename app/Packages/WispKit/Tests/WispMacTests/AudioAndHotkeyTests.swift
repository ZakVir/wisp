import AVFoundation
import CoreGraphics
import XCTest
@testable import WispCore
@testable import WispMac

final class HotkeyMappingTests: XCTestCase {
    func testFlagsMapToModifiers() {
        XCTAssertEqual(HotkeyMonitor.modifiers(from: [.maskControl, .maskAlternate]), [.control, .option])
        XCTAssertEqual(HotkeyMonitor.modifiers(from: [.maskSecondaryFn, .maskCommand, .maskShift]), [.function, .command, .shift])
        // Caps Lock and device-specific bits are ignored.
        XCTAssertEqual(HotkeyMonitor.modifiers(from: [.maskAlphaShift, .maskNonCoalesced]), [])
    }
}

final class AudioRecorderFileSourceTests: XCTestCase {
    /// Writes a 48 kHz stereo sine file (the format a typical USB mic delivers).
    private func makeTone(seconds: Double, amplitude: Float, rate: Double = 48_000, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![c][i] = amplitude * sin(2 * .pi * 440 * Float(i) / Float(rate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testConvertsTo16kMonoAndKeepsTail() async throws {
        // Real-time audio timing: GitHub's virtual machines deliver the file source slower than real hardware.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "timing-sensitive audio test; runs on real Macs")
        let url = try makeTone(seconds: 1.0, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = AudioRecorder()
        recorder.source = .file(url)
        recorder.tail = 0.2
        let chunkCount = LockedCounter()
        recorder.onChunk = { _ in chunkCount.increment() }
        let token = recorder.start()
        try await Task.sleep(for: .seconds(1.0))
        let stopped = await recorder.stop(token)
        let utterance = try XCTUnwrap(stopped)
        XCTAssertEqual(utterance.sampleRate, 16_000)
        // ~1.0 s held + 0.2 s tail, minus start-up latency; allow scheduling jitter.
        XCTAssertEqual(utterance.duration, 1.17, accuracy: 0.12)
        XCTAssertFalse(utterance.isSilent)
        XCTAssertGreaterThan(chunkCount.value, 40)
        XCTAssertLessThan(utterance.firstBufferLatency ?? 1, 0.2)
        // A 0.3-amplitude sine is about -13.5 dBFS RMS.
        XCTAssertEqual(utterance.peakDBFS, -13.5, accuracy: 1.5)
    }

    func testSilentRecordingIsFlagged() async throws {
        let url = try makeTone(seconds: 0.6, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = AudioRecorder()
        recorder.source = .file(url)
        let token = recorder.start()
        try await Task.sleep(for: .seconds(0.5))
        let stopped = await recorder.stop(token)
        let utterance = try XCTUnwrap(stopped)
        XCTAssertTrue(utterance.isSilent)
    }

    func testCancelDiscardsAudio() async throws {
        let url = try makeTone(seconds: 1, amplitude: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = AudioRecorder()
        recorder.source = .file(url)
        let token = recorder.start()
        try await Task.sleep(for: .seconds(0.3))
        recorder.cancel(token)
        let after = await recorder.stop(token)
        XCTAssertNil(after, "nothing to return after cancel")
        XCTAssertFalse(recorder.isRecording)
    }

    func testStaleTokenCannotStopOrCancelANewerRecording() async throws {
        let url = try makeTone(seconds: 2, amplitude: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = AudioRecorder()
        recorder.source = .file(url)
        recorder.tail = 0
        let first = recorder.start()
        try await Task.sleep(for: .seconds(0.2))
        let second = recorder.start()            // barge-in: a new hold supersedes the first
        try await Task.sleep(for: .seconds(0.3))
        recorder.cancel(first)                   // stale cancel must be ignored
        let staleStop = await recorder.stop(first)
        XCTAssertNil(staleStop, "stale stop returns nothing")
        XCTAssertTrue(recorder.isRecording, "the newer recording is still running")
        let fresh = await recorder.stop(second)
        XCTAssertNotNil(fresh)
        XCTAssertLessThan(fresh!.duration, 0.45, "only the second recording's audio")
    }

    func testMissingFileReportsEngineFailure() async throws {
        let recorder = AudioRecorder()
        recorder.source = .file(URL(fileURLWithPath: "/nonexistent/file.wav"))
        let expectation = expectation(description: "error reported")
        recorder.onError = { _, error in
            if case .engineFailed = error { expectation.fulfill() }
        }
        recorder.start()
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertFalse(recorder.isRecording)
    }
}

final class AudioMathTests: XCTestCase {
    func testMeterMapping() {
        XCTAssertEqual(AudioMath.meterLevel(dbfs: -80), 0)
        XCTAssertEqual(AudioMath.meterLevel(dbfs: -8), 1)
        XCTAssertEqual(AudioMath.rmsDBFS([Float](repeating: 0, count: 10)), -160)
        XCTAssertEqual(AudioMath.rmsDBFS([Float](repeating: 1, count: 10)), 0, accuracy: 0.001)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class SecretStoreTests: XCTestCase {
    func testEncryptedRoundTripWithoutPrompts() {
        let account = "wisp-test-\(UUID().uuidString)"
        defer { Keychain.delete(account) }
        XCTAssertNil(Keychain.read(account))
        XCTAssertTrue(Keychain.write("nvapi-test-secret", account: account))
        XCTAssertEqual(Keychain.read(account), "nvapi-test-secret")
        let file = AppPaths.applicationSupport.appendingPathComponent("Secrets/\(account).sealed")
        if let raw = try? Data(contentsOf: file) {
            XCTAssertNil(raw.range(of: Data("nvapi-test-secret".utf8)), "never stored in plain text")
        }
        XCTAssertTrue(Keychain.delete(account))
        XCTAssertNil(Keychain.read(account))
    }
}

final class SpeechNormalizerTests: XCTestCase {
    func testNumbersAndSymbols() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("Press ⌘S to save 3 files"), "Press Command S to save three files")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Set it to 1,456 px"), "Set it to one thousand four hundred fifty six px")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Zoom to 50%"), "Zoom to fifty percent")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Version 2.5 is out."), "Version two point five is out.")
    }

    func testTrimSilence() {
        let s = [Float](repeating: 0, count: 5000) + [Float](repeating: 0.5, count: 100) + [Float](repeating: 0, count: 5000)
        let t = KokoroSpeechEngine.trimSilence(s)
        XCTAssertEqual(t.count, 100 + 2 * 1200)
    }
}

final class VisionStreamErrorTests: XCTestCase {
    func testInStreamErrorsMap() {
        XCTAssertEqual(VisionClient.streamError(["message": "ResourceExhausted: Worker local total request limit reached (16/16)", "code": 500]).code, "http_429")
        XCTAssertEqual(VisionClient.streamError(["message": "Invalid request", "code": 400]).code, "http_400")
        XCTAssertEqual(VisionClient.streamError([:]).code, "http_502")
        XCTAssertTrue(VisionClient.streamError(["message": "ResourceExhausted"]).isRetryableWithAnotherModel)
    }
}
