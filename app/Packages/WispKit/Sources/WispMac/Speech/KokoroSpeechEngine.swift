@preconcurrency import AVFoundation
import CoreML
import WispCore

/// On-device Kokoro voice. Sentences are synthesized one ahead of playback, so after the first sentence the
/// voice never waits on the model. Playback runs on its own AVAudioEngine; `stop()` silences it at once.
public final class KokoroSpeechEngine: TextToSpeechEngine, @unchecked Sendable {
    private let synthQueue = DispatchQueue(label: "com.zakvirani.wisp.kokoro", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by lock.
    private var model: KokoroChain?
    private var g2p: EnglishG2P?
    private var voice: KokoroVoice?
    private var generation = 0
    // Playback.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroChain.sampleRate), channels: 1)!
    /// Multiplies the voice's natural speed (0.5 ... 2.0). Set on the main thread, read while synthesizing.
    private var _speed: Float = 1.0
    public var speed: Float {
        get { lock.withLock { _speed } }
        set { lock.withLock { _speed = newValue } }
    }
    public var volume: Float = 1.0 { didSet { player.volume = volume } }

    /// Speaks a sentence Kokoro couldn't synthesize (the Mac's system voice), so an answer is never silent.
    public var fallback: TextToSpeechEngine?
    private var currentTracker: PlaybackTracker?

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Headphones connected or unplugged, display audio asleep…: the engine stops itself. Restart it and keep
        // playing what's queued, instead of crashing on the next play() or hanging the turn.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.synthQueue.async {
                guard (try? self.engine.start()) != nil else { return }
                if self.lock.withLock({ self.currentTracker != nil }) { self.player.play() }
            }
        }
    }

    public var isReady: Bool { lock.withLock { model != nil && g2p != nil && voice != nil } }

    /// Loads the model, G2P and voice from an installed, verified model folder, then warms up (first synthesis
    /// in a process is 0.5–2 s; afterwards ~0.4 s per sentence).
    public func load(directory: URL) throws {
        let start = ProcessInfo.processInfo.systemUptime
        let model = try KokoroChain(directory: directory)
        let g2p = try EnglishG2P(directory: directory)
        let voice = try KokoroVoice.load(directory.appendingPathComponent("voices/af_heart.bin"))
        if let ph = try? g2p.phonemize("Hello.") {
            _ = try? autoreleasepool { try model.synthesize(phonemeIds: model.tokenIds(ph), style: voice.style(phonemeCount: ph.unicodeScalars.count)) }
        }
        lock.withLock {
            self.model = model
            self.g2p = g2p
            self.voice = voice
        }
        modelDirectory = directory
        Log.speech.info("kokoro loaded and warmed in \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000), privacy: .public) ms")
    }

    /// Folder of the main model (has voices/af_heart.bin) and of the extra-voices download, once installed.
    private var _modelDirectory: URL?
    private var _extraVoicesDirectory: URL?
    private var _currentVoiceID = VoiceCatalog.defaultID
    private var modelDirectory: URL? {
        get { lock.withLock { _modelDirectory } }
        set { lock.withLock { _modelDirectory = newValue } }
    }
    public var extraVoicesDirectory: URL? {
        get { lock.withLock { _extraVoicesDirectory } }
        set { lock.withLock { _extraVoicesDirectory = newValue } }
    }
    public private(set) var currentVoiceID: String {
        get { lock.withLock { _currentVoiceID } }
        set { lock.withLock { _currentVoiceID = newValue } }
    }

    /// Selects a voice by id (falls back to Heart if its file isn't installed). Returns the voice in use.
    @discardableResult
    public func selectVoice(_ id: String) -> String {
        let file: URL?
        if id == VoiceCatalog.defaultID {
            file = modelDirectory?.appendingPathComponent("voices/af_heart.bin")
        } else {
            file = extraVoicesDirectory?.appendingPathComponent("voices/\(id).json")
        }
        guard let file, (try? setVoice(file: file)) != nil else {
            if id != VoiceCatalog.defaultID { return selectVoice(VoiceCatalog.defaultID) }
            return currentVoiceID
        }
        currentVoiceID = id
        return id
    }

    /// Switches to another voice pack ([510,256] fp32 .bin, or a voice .json); takes effect from the next sentence.
    public func setVoice(file: URL) throws {
        let voice = try KokoroVoice.load(file)
        lock.withLock { self.voice = voice }
    }

    /// Synthesizes `text` to 24 kHz mono samples without playing it (voice previews, evaluation).
    public func render(_ text: String) -> [Float] {
        var out: [Float] = []
        for sentence in SentenceSplitter.split(text) {
            synthesize(sentence, quickStart: false) { out += $0; return true }
        }
        return out
    }

    /// The Neural Engine lets an idle model go cold within seconds, and the next sentence then takes 1-2 s
    /// instead of ~0.4 s. A silent synthesis when a question starts (seconds before the answer) keeps it warm.
    public func prewarm() {
        synthQueue.async { [self] in
            guard let (model, g2p, voice) = lock.withLock({ () -> (KokoroChain, EnglishG2P, KokoroVoice)? in
                guard let m = model, let g = g2p, let v = voice else { return nil }
                return (m, g, v)
            }), let ph = try? g2p.phonemize("Hello.") else { return }
            _ = try? autoreleasepool { try model.synthesize(phonemeIds: model.tokenIds(ph), style: voice.style(phonemeCount: ph.unicodeScalars.count)) }
        }
    }

    /// Phoneme ids and voice style for one sentence (for comparing other Kokoro builds in wisp-bench).
    public func modelInputs(for sentence: String) -> (ids: [Int32], style: [Float], phonemes: String)? {
        guard let (model, g2p, voice) = lock.withLock({ () -> (KokoroChain, EnglishG2P, KokoroVoice)? in
            guard let m = model, let g = g2p, let v = voice else { return nil }
            return (m, g, v)
        }), let ph = try? g2p.phonemize(SpeechTextNormalizer.normalize(sentence)) else { return nil }
        let ids = model.tokenIds(ph)
        return (ids, voice.style(phonemeCount: ph.unicodeScalars.count), ph)
    }

    public func unload() {
        stop()
        lock.withLock { model = nil; g2p = nil; voice = nil }
    }

    public func speak(_ sentences: AsyncStream<String>, onSentenceStart: @escaping @Sendable (Int, String) -> Void,
                      onFirstAudio: @escaping @Sendable () -> Void) async {
        let myGeneration = lock.withLock { () -> Int in generation += 1; return generation }
        let tracker = PlaybackTracker(onSentenceStart: onSentenceStart, onFirstAudio: onFirstAudio)
        lock.withLock { currentTracker = tracker }
        defer { lock.withLock { if currentTracker === tracker { currentTracker = nil } } }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.speech.error("kokoro playback engine failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        player.volume = volume
        var index = 0
        for await sentence in sentences {
            guard isCurrent(myGeneration) else { break }
            let i = index
            index += 1
            // Synthesize piece by piece on the synth queue; each piece is scheduled the moment it's ready, so long
            // sentences start playing after their first clause instead of after the whole sentence.
            let firstOfAnswer = i == 0
            // Wisp's own voice speaks English only: another language goes to the Mac's voice for it.
            let foreign = fallback != nil && SpokenLanguage.nonEnglishCode(sentence) != nil
            let producedAudio = foreign ? false : await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let queued = ProcessInfo.processInfo.systemUptime
                synthQueue.async { [self] in
                    var first = true
                    let began = ProcessInfo.processInfo.systemUptime
                    synthesize(sentence, quickStart: firstOfAnswer) { samples in
                        if first && firstOfAnswer {
                            let now = ProcessInfo.processInfo.systemUptime
                            Log.speech.info("kokoro first piece: waited \(Int((began - queued) * 1000), privacy: .public) ms, synthesized in \(Int((now - began) * 1000), privacy: .public) ms")
                        }
                        guard self.isCurrent(myGeneration) else { return false }
                        self.schedule(samples: samples, sentenceIndex: i, text: sentence, firstChunk: first, tracker: tracker,
                                      generation: myGeneration)
                        first = false
                        return true
                    }
                    c.resume(returning: !first)
                }
            }
            if !producedAudio, isCurrent(myGeneration), let fallback {
                // Kokoro couldn't voice this sentence (or it isn't English): the system voice, after what's already queued.
                if !foreign { Log.speech.error("kokoro produced no audio for a sentence; using the system voice") }
                await tracker.waitUntilDrained(timeout: tracker.scheduledSeconds + 5)
                let (one, sink) = AsyncStream.makeStream(of: String.self)
                sink.yield(sentence)
                sink.finish()
                await fallback.speak(one, onSentenceStart: { _, text in onSentenceStart(i, text) }, onFirstAudio: onFirstAudio)
            }
        }
        // Wait until everything scheduled has played (or was stopped); never longer than the audio itself plus slack.
        await tracker.waitUntilDrained(timeout: tracker.scheduledSeconds + 5)
        if isCurrent(myGeneration) {
            // Release the audio device shortly after finishing (keeps it if another answer follows quickly).
            synthQueue.asyncAfter(deadline: .now() + 2) { [self] in
                if isCurrent(myGeneration) && !player.isPlaying { engine.pause() }
            }
        }
    }

    public var outputLatency: Double { engine.outputNode.presentationLatency }

    public func stop() {
        let tracker = lock.withLock { () -> PlaybackTracker? in generation += 1; return currentTracker }
        tracker?.cancel()
        fallback?.stop()
        player.stop() // drops queued buffers; their completion handlers fire, draining the tracker
    }

    // MARK: Private

    private func isCurrent(_ g: Int) -> Bool { lock.withLock { generation == g } }

    private func schedule(samples: [Float], sentenceIndex: Int, text: String, firstChunk: Bool, tracker: PlaybackTracker,
                          generation: Int) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        tracker.scheduled(sentence: sentenceIndex, text: text, firstChunk: firstChunk,
                          seconds: Double(samples.count) / format.sampleRate)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            tracker.played(sentence: sentenceIndex)
        }
        // The engine may have stopped (audio route change): play() on a stopped engine raises an exception.
        if !engine.isRunning { try? engine.start() }
        if engine.isRunning && !player.isPlaying && isCurrent(generation) { player.play() }
    }

    /// Text → phonemes → audio pieces that fit the model's 126-phoneme / 5-second window. Each piece is handed to
    /// `emit` as soon as it is synthesized (return false to stop). With `quickStart`, a long sentence is split at
    /// its first natural break so the first sound comes sooner.
    private func synthesize(_ sentence: String, quickStart: Bool, emit: ([Float]) -> Bool) {
        guard let (model, g2p, voice) = lock.withLock({ () -> (KokoroChain, EnglishG2P, KokoroVoice)? in
            guard let m = model, let g = g2p, let v = voice else { return nil }
            return (m, g, v)
        }) else { return }
        let text = SpeechTextNormalizer.normalize(sentence)
        guard let phonemes = try? g2p.phonemize(text) else { return }
        // A whole sentence goes in one call (up to 510 phonemes); only longer text is split, at a natural break.
        _ = quickStart
        var queue: [String] = [phonemes]
        var guardCount = 0
        while !queue.isEmpty, guardCount < 32 {
            guardCount += 1
            let ph = queue.removeFirst()
            let ids = model.tokenIds(ph)
            if ids.isEmpty { continue }
            if ids.count > KokoroChain.maxPhonemes {
                let (a, b) = Chunker.split(ph)
                queue.insert(contentsOf: [a, b].filter { !$0.isEmpty }, at: 0)
                continue
            }
            // The voice pack's style row is chosen by the phoneme string's length, as upstream Kokoro does.
            let result = try? autoreleasepool {
                try model.synthesize(phonemeIds: ids, style: voice.style(phonemeCount: ph.unicodeScalars.count), speed: speed)
            }
            guard let result else { continue }
            var samples = Self.trimSilence(result)
            if queue.isEmpty { samples += [Float](repeating: 0, count: KokoroChain.sampleRate / 12) } // breath after the sentence
            if !emit(samples) { return }
        }
    }

    /// Kokoro pads ~0.3 s of silence at both ends; trim most of it so sentences flow naturally.
    static func trimSilence(_ s: [Float], threshold: Float = 0.004, keep: Int = 1200) -> [Float] {
        guard let first = s.firstIndex(where: { abs($0) > threshold }),
              let last = s.lastIndex(where: { abs($0) > threshold }) else { return s }
        let start = max(0, first - keep)
        let end = min(s.count, last + 1 + keep)
        return Array(s[start..<end])
    }
}

/// Fires sentence-start callbacks in playback order and resumes the waiter when all audio has played.
final class PlaybackTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding: [Int: Int] = [:]          // sentence → buffers not yet played
    private var texts: [Int: String] = [:]
    private var order: [Int] = []
    private var announced = Set<Int>()
    private var waiter: CheckedContinuation<Void, Never>?
    private var firstAudioFired = false
    /// Set by `stop()`: a cut-off answer must not caption its next sentence.
    private var cancelled = false
    /// Total audio handed to the player, an upper bound on how long draining can take.
    private(set) var scheduledSeconds: Double = 0

    func cancel() { lock.withLock { cancelled = true } }
    private let onSentenceStart: @Sendable (Int, String) -> Void
    private let onFirstAudio: @Sendable () -> Void

    init(onSentenceStart: @escaping @Sendable (Int, String) -> Void, onFirstAudio: @escaping @Sendable () -> Void) {
        self.onSentenceStart = onSentenceStart
        self.onFirstAudio = onFirstAudio
    }

    func scheduled(sentence: Int, text: String, firstChunk: Bool, seconds: Double = 0) {
        var announce: (Int, String)?
        var first = false
        lock.withLock {
            scheduledSeconds += seconds
            outstanding[sentence, default: 0] += 1
            if firstChunk { texts[sentence] = text; order.append(sentence) }
            // If nothing earlier is still playing, this sentence starts now.
            if firstChunk, order.first == sentence, !announced.contains(sentence) {
                announced.insert(sentence)
                announce = (sentence, text)
                if !firstAudioFired { firstAudioFired = true; first = true }
            }
        }
        if first { onFirstAudio() }
        if let announce, !lock.withLock({ cancelled }) { onSentenceStart(announce.0, announce.1) }
    }

    func played(sentence: Int) {
        var announce: (Int, String)?
        var resume: CheckedContinuation<Void, Never>?
        lock.withLock {
            outstanding[sentence, default: 1] -= 1
            if outstanding[sentence] == 0 {
                outstanding.removeValue(forKey: sentence)
                order.removeAll { $0 == sentence }
                if let next = order.first, !announced.contains(next), let text = texts[next] {
                    announced.insert(next)
                    announce = (next, text)
                }
            }
            if outstanding.isEmpty, let w = waiter { waiter = nil; resume = w }
            if cancelled { announce = nil }
        }
        if let announce { onSentenceStart(announce.0, announce.1) }
        resume?.resume()
    }

    /// Returns when everything scheduled has played, or after `timeout` seconds at most (a stalled audio device
    /// must never leave a turn hanging).
    func waitUntilDrained(timeout: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if outstanding.isEmpty { return true }
                waiter = c
                return false
            }
            if done { c.resume(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                let late = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    defer { waiter = nil }
                    return waiter
                }
                late?.resume()
            }
        }
    }
}

/// Makes text speakable: numbers, symbols and shortcut glyphs spelled out (Kokoro's lexicon has no digits).
public enum SpeechTextNormalizer {
    private static let replacements: [(String, String)] = [
        ("⌘", " Command "), ("⌥", " Option "), ("⌃", " Control "), ("⇧", " Shift "), ("↩", " Return "),
        ("⌫", " Delete "), ("⌦", " Forward Delete "), ("⎋", " Escape "), ("⇥", " Tab "), ("␣", " Space "), (" → ", ", then "), (" > ", ", then "), ("→", " to "), ("&", " and "), ("%", " percent"), ("+", " plus "), ("@", " at "),
        ("e.g.", "for example"), ("i.e.", "that is"), ("etc.", "and so on"),
    ]

    /// "https://www.example.com/path?x=1" → "a link to example.com"; "name@example.com" stays readable.
    static func speakableLinks(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:https?://|www\.)([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?:[/?#][^\s]*)?"#) else { return text }
        let ns = text as NSString
        var out = text
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var host = ns.substring(with: m.range(at: 1))
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            out = (out as NSString).replacingCharacters(in: m.range, with: "a link to " + host)
        }
        return out
    }

    public static func normalize(_ text: String) -> String {
        let text = speakableLinks(text)
        // An arrow right after a modifier key is a key of its own: "⌘→" is Command Right Arrow, not "Command to".
        var t = text.replacingOccurrences(of: #"([⌘⌥⌃⇧])\s?([←→↑↓])"#, with: "$1 $2Arrow", options: .regularExpression)
        for (arrow, name) in [("←Arrow", " Left Arrow "), ("→Arrow", " Right Arrow "), ("↑Arrow", " Up Arrow "), ("↓Arrow", " Down Arrow ")] {
            t = t.replacingOccurrences(of: arrow, with: name)
        }
        for (a, b) in replacements { t = t.replacingOccurrences(of: a, with: b) }
        t = spellAcronyms(t)
        t = spellNumbers(t)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Abbreviations people say as words; every other all-caps abbreviation is read letter by letter.
    private static let sayAsWord: Set<String> = [
        "NASA", "JPEG", "JPG", "GIF", "RAM", "ROM", "PIN", "SIM", "LAN", "WAN", "NATO", "FIFA", "ASAP", "SCUBA",
        "CAPTCHA", "GUI", "WYSIWYG", "LOL", "UNESCO", "UNICEF", "COVID", "LASER", "RADAR", "SONAR", "OPEC",
    ]
    private static let acronym = try! NSRegularExpression(pattern: #"\b([A-Z]{2,6})(s?)\b"#)
    private static let osName = try! NSRegularExpression(pattern: #"\b(mac|iPad|watch|tv|vision)OS\b"#)

    /// "PDF" → "P D F", "URLs" → "U R L's", "macOS" → "mac O S", "OK" → "okay"; NASA, JPEG… stay words.
    static func spellAcronyms(_ text: String) -> String {
        var t = osName.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1 O S")
        t = t.replacingOccurrences(of: #"\bOK\b"#, with: "okay", options: .regularExpression)
        let ns = t as NSString
        var out = ""
        var last = 0
        for match in acronym.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range(at: 1))
            guard !sayAsWord.contains(word) else { continue }
            let plural = match.range(at: 2).length > 0
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            // A lone "A" would be read as the article ("uh"); "ay" is the letter's name.
            out += word.map { $0 == "A" ? "ay" : String($0) }.joined(separator: " ") + (plural ? "'s" : "")
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func spellNumbers(_ text: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        var out = ""
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            let clean = digits.replacingOccurrences(of: ",", with: "")
            if let n = Double(clean), let words = formatter.string(from: NSNumber(value: n)) {
                out += words.replacingOccurrences(of: "-", with: " ")
            } else {
                out += digits
            }
            digits = ""
        }
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            let nextIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
            if c.isNumber || ((c == "." || c == ",") && !digits.isEmpty && nextIsDigit) {
                digits.append(c)
            } else {
                flush()
                out.append(c)
            }
        }
        flush()
        return out
    }
}
