@preconcurrency import AVFoundation
import AudioToolbox
import os
import WispCore

/// Push-to-talk microphone capture.
///
/// - The engine is built and prepared ahead of time and reused across turns, so a press only has to
///   *start* it (no cold build on the hot path). It is rebuilt when the audio device changes.
/// - Each recording gets a token; stale stops, cancels and watchdogs from an older recording can never
///   touch a newer one.
/// - Converts whatever the device delivers to 16 kHz mono Float32, streams chunks to `onChunk`, and keeps
///   the utterance in memory only (never written to disk).
/// - A watchdog rebuilds the engine once if no audio arrives, then reports `.noAudio`.
///
/// Threading: all state lives on a private serial queue. Public methods never block the caller on it,
/// except the cheap `isRecording` read, which uses a lock-protected mirror.
public final class AudioRecorder: @unchecked Sendable {
    public enum RecorderError: Error, Equatable, Sendable {
        case permissionDenied
        case noInputDevice
        case engineFailed(String)
        /// The engine started but no audio arrived (muted interface, broken driver, unplugged device).
        case noAudio
    }

    public struct Token: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    public static let targetSampleRate: Double = 16_000

    /// Called on the recorder's queue with each converted chunk. Do not call back into the recorder from it.
    public var onChunk: (@Sendable ([Float]) -> Void)?
    /// Smoothed 0...1 input level, delivered on the main actor at up to ~30 Hz.
    public var onLevel: (@MainActor @Sendable (Float) -> Void)?
    /// The first audio buffer of a recording arrived (the microphone is really live).
    public var onFirstBuffer: (@MainActor @Sendable (Token) -> Void)?
    /// A recording failed, delivered on the main actor.
    public var onError: (@MainActor @Sendable (Token, RecorderError) -> Void)?

    /// Seconds of audio kept after key-up.
    public var tail: TimeInterval = 0.2
    public var preferBuiltInOverBluetooth = true
    /// Microphone chosen in Settings (device UID), or nil for the system default. Takes effect on the next press.
    public var chosenInputUID: String? {
        get { inputLock.withLock { _chosenInputUID } }
        set {
            let changed = inputLock.withLock { () -> Bool in
                defer { _chosenInputUID = newValue }
                return _chosenInputUID != newValue
            }
            if changed { queue.async { [self] in if active == nil { teardownEngine() } }; prepare() }
        }
    }
    /// Written on the main thread, read on the audio queue when the engine is built.
    private var _chosenInputUID: String?
    private let inputLock = NSLock()
    /// `.file` replays a recording in real time through the same conversion path (tests, benchmarks and
    /// debug builds via `WISP_FAKE_MIC_FILE`).
    public var source: Source = .microphone

    public enum Source: Sendable, Equatable {
        case microphone
        case file(URL)
    }

    private let queue = DispatchQueue(label: "com.zakvirani.wisp.audio", qos: .userInteractive)
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.targetSampleRate,
                                             channels: 1, interleaved: false)!
    private let mirror = OSAllocatedUnfairLock(initialState: false) // isRecording, readable from any thread

    // Queue-only state.
    private var engine: AVAudioEngine?
    private var engineReady = false
    private var converter: AVAudioConverter?
    private var fileTimer: DispatchSourceTimer?
    private let tokenCounter = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var active: Token?
    private var samples: [Float] = []
    private var startUptime: TimeInterval = 0
    private var firstBufferUptime: TimeInterval?
    private var loudestDBFS: Float = -160
    private var smoothedLevel: Float = 0
    private var lastLevelSent: TimeInterval = 0
    private var restartedByWatchdog = false
    /// Engine rebuilds after configuration changes in the current recording (capped so they can never loop).
    private var configRestarts = 0
    /// When the engine was last built: notices right after a build are self-inflicted (device selection).
    private var lastBuild: TimeInterval = 0
    private var configObserver: NSObjectProtocol?

    public init() {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let changed = note.object.map { ObjectIdentifier($0 as AnyObject) }
            self.queue.async {
                guard let engine = self.engine, changed == ObjectIdentifier(engine) else { return }
                self.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Builds and prepares the engine ahead of the first press (call at launch and after permission grants).
    public func prepare() {
        queue.async { [self] in
            guard source == .microphone, active == nil, !engineReady,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            do { try buildEngine() } catch {
                Log.audio.error("prepare failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Begins capturing without blocking the caller. Problems are reported through `onError`.
    @discardableResult
    public func start(at keyDownUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Token {
        // A lock, not queue.sync: the capture queue may be busy building the engine, and this runs on key-down.
        let token = tokenCounter.withLock { value -> Token in
            value += 1
            return Token(value: value)
        }
        queue.async { [self] in
            if active != nil { stopCapture() }
            if source == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                report(token, .permissionDenied)
                return
            }
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(Int(Self.targetSampleRate * 30))
            startUptime = keyDownUptime
            firstBufferUptime = nil
            loudestDBFS = -160
            smoothedLevel = 0
            restartedByWatchdog = false
            configRestarts = 0
            active = token
            mirror.withLock { $0 = true }
            do {
                try startCapture()
            } catch {
                finishActive()
                report(token, (error as? RecorderError) ?? .engineFailed(String(describing: error)))
                return
            }
            scheduleWatchdog(for: token)
        }
        return token
    }

    /// Waits for the tail, then stops and returns the utterance. Returns nil if `token` is no longer the
    /// active recording (cancelled or superseded) or if the calling task was cancelled.
    public func stop(_ token: Token) async -> Utterance? {
        if tail > 0 {
            do { try await Task.sleep(for: .seconds(tail)) } catch { return nil }
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard active == token else { continuation.resume(returning: nil); return }
                let utterance = Utterance(samples: samples, sampleRate: Self.targetSampleRate,
                                          firstBufferLatency: firstBufferUptime.map { $0 - startUptime },
                                          peakDBFS: loudestDBFS)
                stopCapture()
                finishActive()
                continuation.resume(returning: utterance)
            }
        }
    }

    /// Stops immediately and discards the audio (cancelled turn). No-op for a stale token.
    public func cancel(_ token: Token) {
        queue.async { [self] in
            guard active == token else { return }
            stopCapture()
            finishActive()
            let onLevel = self.onLevel
            Task { @MainActor in onLevel?(0) }
        }
    }

    public var isRecording: Bool { mirror.withLock { $0 } }

    // MARK: - Engine (queue only)

    private func buildEngine() throws {
        teardownEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Select a device only when it isn't the system default: selecting one (even the same one) makes the engine
        // post a configuration-change notice, which used to trigger a rebuild loop and "no audio" (2026-10-01).
        if let device = AudioDevices.preferredInput(chosenUID: chosenInputUID, preferBuiltInOverBluetooth: preferBuiltInOverBluetooth),
           device.id != AudioDevices.defaultInput()?.id {
            if let unit = input.audioUnit {
                var id = device.id
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                  &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr { Log.audio.error("could not select input device (status \(status, privacy: .public)); using default") }
            } else {
                Log.audio.notice("input audio unit unavailable; using the default input device")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Copy out of the realtime callback immediately; convert on our queue.
            guard let self, let copy = Self.copy(buffer) else { return }
            self.queue.async { self.process(copy) }
        }
        engine.prepare()
        self.engine = engine
        engineReady = true
        lastBuild = ProcessInfo.processInfo.systemUptime
        Log.audio.info("mic engine prepared: \(Int(format.sampleRate), privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        engineReady = false
    }

    private func startCapture() throws {
        if case .file(let url) = source { return try startFilePlayback(url) }
        if !engineReady { try buildEngine() }
        guard let engine else { throw RecorderError.noInputDevice }
        let format = engine.inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: outputFormat)
        converter?.downmix = true
        do {
            try engine.start()
        } catch {
            // A stale prepared engine (device changed while idle): rebuild once and retry.
            try buildEngine()
            if let fresh = self.engine {
                converter = AVAudioConverter(from: fresh.inputNode.outputFormat(forBus: 0), to: outputFormat)
                converter?.downmix = true
                try fresh.start()
            }
        }
    }

    /// Stops capture but keeps the engine prepared for the next press.
    private func stopCapture() {
        if let fileTimer {
            fileTimer.cancel()
            self.fileTimer = nil
        } else {
            engine?.stop()
        }
        converter = nil
    }

    private func finishActive() {
        active = nil
        samples.removeAll(keepingCapacity: false)
        mirror.withLock { $0 = false }
    }

    private func report(_ token: Token, _ error: RecorderError) {
        Log.audio.error("recorder error: \(String(describing: error), privacy: .public)")
        let onError = self.onError
        Task { @MainActor in onError?(token, error) }
    }

    /// Feeds a file in 20 ms buffers at real-time pace; after it ends, feeds silence (like a mic).
    private func startFilePlayback(_ url: URL) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw RecorderError.engineFailed("cannot open audio file") }
        let format = file.processingFormat
        converter = AVAudioConverter(from: format, to: outputFormat)
        converter?.downmix = true
        let frames = AVAudioFrameCount(format.sampleRate * 0.02)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.03, repeating: 0.02, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            if file.framePosition < file.length { try? file.read(into: buffer, frameCount: frames) }
            if buffer.frameLength == 0 {
                buffer.frameLength = frames
                if let data = buffer.floatChannelData {
                    for c in 0..<Int(format.channelCount) { data[c].update(repeating: 0, count: Int(frames)) }
                }
            }
            self.process(buffer)
        }
        fileTimer = timer
        timer.resume()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let token = active, let converter else { return }
        if firstBufferUptime == nil {
            firstBufferUptime = ProcessInfo.processInfo.systemUptime
            let onFirstBuffer = self.onFirstBuffer
            Task { @MainActor in onFirstBuffer?(token) }
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let data = out.floatChannelData, out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        samples.append(contentsOf: chunk)
        onChunk?(chunk)

        let db = chunk.withUnsafeBufferPointer { AudioMath.rmsDBFS($0) }
        loudestDBFS = max(loudestDBFS, db)
        smoothedLevel = AudioMath.smooth(previous: smoothedLevel, next: AudioMath.meterLevel(dbfs: db))
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelSent > 1.0 / 30.0 {
            lastLevelSent = now
            let level = smoothedLevel
            let onLevel = self.onLevel
            Task { @MainActor in onLevel?(level) }
        }
    }

    private func handleConfigurationChange() {
        guard source == .microphone else { return }
        guard let token = active else {
            // Our own device selection posts a notice right after a build: not a real change.
            if ProcessInfo.processInfo.systemUptime - lastBuild < 1.0 { return }
            // Device changed while idle: rebuild lazily on the next press.
            teardownEngine()
            return
        }
        // A notice while the engine keeps running is not a real change (e.g. selecting the input device posts one).
        if engine?.isRunning == true {
            Log.audio.info("audio configuration notice while running; ignored")
            return
        }
        // Device plugged/unplugged mid-recording: the engine stopped itself. Rebuild and keep the audio so far.
        configRestarts += 1
        guard configRestarts <= 2 else {
            Log.audio.error("audio configuration keeps changing; giving up on this recording")
            stopCapture()
            finishActive()
            report(token, .noAudio)
            return
        }
        Log.audio.notice("audio configuration changed during recording; restarting engine")
        do {
            try buildEngine()
            try startCapture()
        } catch {
            stopCapture()
            finishActive()
            report(token, (error as? RecorderError) ?? .engineFailed(String(describing: error)))
        }
    }

    private func scheduleWatchdog(for token: Token) {
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.active == token, self.firstBufferUptime == nil else { return }
            if !self.restartedByWatchdog {
                Log.audio.notice("no microphone audio after 400 ms; rebuilding engine")
                self.restartedByWatchdog = true
                do {
                    self.stopCapture()
                    if self.source == .microphone { try self.buildEngine() }
                    try self.startCapture()
                } catch {
                    self.finishActive()
                    self.report(token, (error as? RecorderError) ?? .engineFailed(String(describing: error)))
                    return
                }
                self.scheduleWatchdog(for: token)
            } else {
                self.stopCapture()
                self.finishActive()
                self.report(token, .noAudio)
            }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let planes = buffer.format.isInterleaved ? 1 : channels
        let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? channels : 1)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<planes { dst[c].update(from: src[c], count: count) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0..<planes { dst[c].update(from: src[c], count: count) }
        } else {
            return nil
        }
        return copy
    }
}
