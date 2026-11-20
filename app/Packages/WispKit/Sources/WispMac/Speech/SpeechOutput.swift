@preconcurrency import AVFoundation
import NaturalLanguage
import WispCore

/// Text-to-speech engine adapter: synthesizes one sentence to 24 kHz-ish mono PCM, or speaks directly.
public protocol TextToSpeechEngine: AnyObject, Sendable {
    var isReady: Bool { get }
    /// Speaks `sentences` in order; calls `onSentenceStart` as each one begins (for captions and pointing),
    /// and `onFirstAudio` once the first sound plays. Returns when all are spoken or `stop()` was called.
    func speak(_ sentences: AsyncStream<String>, onSentenceStart: @escaping @Sendable (Int, String) -> Void,
               onFirstAudio: @escaping @Sendable () -> Void) async
    /// Stops immediately (barge-in).
    func stop()
    /// Seconds between stopping the player and the speaker going quiet (device output latency).
    var outputLatency: Double { get }
    /// Called when a question starts: get ready to speak soon (silently).
    func prewarm()
}

extension TextToSpeechEngine {
    public var outputLatency: Double { 0 }
    public func prewarm() {}
}

/// Fallback voice while the on-device model is downloading: the system voice (AVSpeechSynthesizer).
public final class SystemSpeechEngine: NSObject, TextToSpeechEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var finished: [Int: CheckedContinuation_Bool] = [:]
    private var started: (@Sendable () -> Void)?
    private var stopped = false
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var volume: Float = 1

    public override init() {
        super.init()
        synth.delegate = self
    }

    public var isReady: Bool { true }

    public func speak(_ sentences: AsyncStream<String>, onSentenceStart: @escaping @Sendable (Int, String) -> Void,
                      onFirstAudio: @escaping @Sendable () -> Void) async {
        lock.withLock { stopped = false; started = onFirstAudio }
        var index = 0
        for await sentence in sentences {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.rate = rate
            utterance.volume = volume
            // Another language (a question typed in Spanish, an answer the user asked for in French): a macOS voice for it.
            utterance.voice = AVSpeechSynthesisVoice(language: SpokenLanguage.nonEnglishCode(sentence) ?? "en-US")
            // Check "stopped" and register in one critical section, so a stop() can never slip in between and
            // let a sentence play after barge-in.
            let proceed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let go = lock.withLock { () -> Bool in
                    guard !stopped else { return false }
                    finished[ObjectIdentifier(utterance).hashValue] = CheckedContinuation_Bool(continuation)
                    return true
                }
                if go {
                    onSentenceStart(index, sentence)
                    synth.speak(utterance)
                } else {
                    continuation.resume(returning: false)
                }
            }
            if !proceed { break }
            index += 1
        }
    }

    public func stop() {
        lock.withLock { stopped = true }
        synth.stopSpeaking(at: .immediate)
        let pending = lock.withLock { () -> [CheckedContinuation_Bool] in
            let p = Array(finished.values)
            finished.removeAll()
            return p
        }
        pending.forEach { $0.resume(false) }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let cb = lock.withLock { () -> (@Sendable () -> Void)? in
            let c = started
            started = nil
            return c
        }
        cb?()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume(utterance)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume(utterance)
    }

    private func resume(_ utterance: AVSpeechUtterance) {
        let c = lock.withLock { finished.removeValue(forKey: ObjectIdentifier(utterance).hashValue) }
        c?.resume(true)
    }
}

/// A Bool continuation wrapper (so stop() can tell the speak loop to end).
struct CheckedContinuation_Bool {
    private let c: CheckedContinuation<Bool, Never>
    init(_ c: CheckedContinuation<Bool, Never>) { self.c = c }
    func resume(_ value: Bool) { c.resume(returning: value) }
}


/// Which language a sentence is in, when it clearly isn't English and macOS has a voice for it (Wisp's own voice
/// only speaks English).
public enum SpokenLanguage {
    public static func nonEnglishCode(_ sentence: String) -> String? {
        guard sentence.split(separator: " ").count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sentence)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .english, language != .undetermined, confidence >= 0.75 else { return nil }
        let code = language.rawValue
        return AVSpeechSynthesisVoice(language: code) != nil ? code : nil
    }
}
