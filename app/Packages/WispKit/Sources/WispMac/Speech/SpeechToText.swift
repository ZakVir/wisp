import Foundation
import os
import MoonshineVoice
import WispCore

/// A finished transcription for one turn. Text only, kept in memory; never logged.
public struct Transcript: Sendable, Equatable {
    public var text: String
    /// Seconds from `finish()` to the final text.
    public var finalizeLatency: TimeInterval
    public init(text: String, finalizeLatency: TimeInterval) {
        self.text = text
        self.finalizeLatency = finalizeLatency
    }
}

public enum SpeechToTextError: Error, Equatable, Sendable {
    /// The on-device model isn't installed yet (still downloading).
    case modelNotReady
    case failed(String)
}

/// Streaming speech-to-text adapter. One utterance at a time: `begin` → `append`… → `finish` (or `cancel`).
public protocol SpeechToText: AnyObject, Sendable {
    var isReady: Bool { get }
    func begin(keyterms: [String]) throws
    /// 16 kHz mono Float32 audio. Safe to call from any thread.
    func append(_ samples: [Float])
    /// Ends the utterance and returns the final text.
    func finish() async throws -> Transcript
    func cancel()
}

/// Moonshine v2 Small (streaming, English) through `moonshine-swift`.
///
/// Inference runs inline inside `addAudio`, so all calls go through one serial queue, never the audio thread.
public final class MoonshineSpeechToText: SpeechToText, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zakvirani.wisp.stt", qos: .userInitiated)
    // Queue-only state.
    private var transcriber: Transcriber?
    private var stream: MoonshineVoice.Stream?
    private var modelDirectory: URL?
    private var lines: [UInt64: String] = [:]
    private var lineOrder: [UInt64] = []
    private var appendedSamples = 0
    private var active = false
    private var beginError: Error?
    private var lastUsed = Date()
    private var idleTimer: DispatchSourceTimer?

    /// Unload the model after this long without use (it holds ~0.5 GB).
    public var idleUnloadAfter: TimeInterval = 600

    public init() {}

    /// Lock-protected mirror of "a model is loaded and usable", readable from the main thread without waiting
    /// for the STT queue (which may be busy loading or transcribing).
    private let readyFlag = OSAllocatedUnfairLock(initialState: false)
    public var isReady: Bool { readyFlag.withLock { $0 } }

    /// Loads the model and runs one silent inference so the first real question is fast. Loading a new version
    /// replaces the old one. Throws (and stays not-ready) if the files can't be loaded.
    public func load(directory: URL) throws {
        try queue.sync {
            if modelDirectory != directory {
                stream?.close(); stream = nil
                transcriber?.close(); transcriber = nil
            }
            modelDirectory = directory
            do {
                try ensureLoaded()
            } catch {
                modelDirectory = nil
                readyFlag.withLock { $0 = false }
                throw error
            }
            readyFlag.withLock { $0 = true }
            // Warm-up: the first inference in a process is ~1.5× slower.
            _ = try? transcriber?.transcribeWithoutStreaming(audioData: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
            scheduleIdleUnload()
        }
    }

    /// Forgets the model (Remove/Repair). Returns at once: new utterances are refused immediately, and the
    /// model is closed on the STT queue after any transcription in progress.
    public func unload() {
        readyFlag.withLock { $0 = false }
        queue.async { [self] in
            stream?.close()
            stream = nil
            transcriber?.close()
            transcriber = nil
            modelDirectory = nil
            readyFlag.withLock { $0 = false }
        }
    }

    /// Starts an utterance without blocking the caller (loading the model, if it was unloaded, happens on the
    /// STT queue; audio appended meanwhile is queued behind it, so nothing is lost).
    public func begin(keyterms: [String]) throws {
        guard isReady else { throw SpeechToTextError.modelNotReady }
        queue.async { [self] in
            beginError = nil
            do {
                try ensureLoaded()
                lines.removeAll()
                lineOrder.removeAll()
                try? transcriber?.setKeyterms(keyterms)
                if stream == nil {
                    let s = try transcriber!.createStream(updateInterval: 0.25)
                    s.addListener { [weak self] event in
                        // Listener runs on the calling queue (ours).
                        guard let self else { return }
                        if let e = event as? LineCompleted { self.record(e.line) }
                        if let e = event as? LineTextChanged { self.record(e.line) }
                    }
                    stream = s
                }
                try stream?.start()
                appendedSamples = 0
                active = true
                lastUsed = Date()
            } catch {
                beginError = error
                active = false
            }
        }
    }

    public func append(_ samples: [Float]) {
        queue.async { [self] in
            guard active, let stream else { return }
            appendedSamples += samples.count
            do { try stream.addAudio(samples, sampleRate: 16_000) } catch {
                Log.speech.error("stt addAudio failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func finish() async throws -> Transcript {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard active, let stream else {
                    let error = beginError.map { SpeechToTextError.failed(String(describing: $0)) } ?? .modelNotReady
                    continuation.resume(throwing: error)
                    return
                }
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    try stream.stop() // emits the final LineCompleted synchronously
                } catch {
                    active = false
                    continuation.resume(throwing: SpeechToTextError.failed(String(describing: error)))
                    return
                }
                active = false
                lastUsed = Date()
                let received = Double(appendedSamples) / 16_000
                Log.speech.info("stt received \(String(format: "%.2f", received), privacy: .public) s of audio")
                let text = lineOrder.compactMap { lines[$0] }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: Transcript(text: text, finalizeLatency: ProcessInfo.processInfo.systemUptime - start))
            }
        }
    }

    public func cancel() {
        queue.async { [self] in
            guard active else { return }
            try? stream?.stop()
            active = false
            lines.removeAll()
            lineOrder.removeAll()
        }
    }

    // MARK: Queue-only helpers

    private func ensureLoaded() throws {
        guard transcriber == nil else { return }
        guard let dir = modelDirectory else { throw SpeechToTextError.modelNotReady }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            transcriber = try Transcriber(modelPath: dir.path, modelArch: .smallStreaming)
        } catch {
            throw SpeechToTextError.failed(String(describing: error))
        }
        Log.speech.info("moonshine loaded in \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000), privacy: .public) ms")
    }

    private func record(_ line: TranscriptLine) {
        if lines[line.lineId] == nil { lineOrder.append(line.lineId) }
        lines[line.lineId] = line.text
    }

    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, !self.active, self.transcriber != nil,
                  Date().timeIntervalSince(self.lastUsed) > self.idleUnloadAfter else { return }
            self.stream?.close()
            self.stream = nil
            self.transcriber?.close()
            self.transcriber = nil
            Log.speech.info("moonshine unloaded after idle (reloads on next question)")
        }
        timer.resume()
        idleTimer = timer
    }
}
