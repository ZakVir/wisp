@preconcurrency import AVFoundation
import WispCore

/// Short, soft confirmation sounds, synthesized in memory (no bundled audio files).
public final class EarconPlayer: @unchecked Sendable {
    public enum Sound: Sendable {
        /// The microphone is live (played once the first audio buffer arrives).
        case listening
        /// Recording finished, thinking.
        case done
        /// Something went wrong (no audio heard, request failed).
        case problem
    }

    public var enabled = true
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private let queue = DispatchQueue(label: "com.zakvirani.wisp.earcons")
    private var generation = 0
    private var busyUntil = DispatchTime.now()

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffers[.listening] = render(notes: [(659.25, 0.055), (987.77, 0.085)], gain: 0.10)
        buffers[.done] = render(notes: [(880.0, 0.05), (659.25, 0.08)], gain: 0.08)
        buffers[.problem] = render(notes: [(440.0, 0.08), (349.23, 0.12)], gain: 0.09)
    }

    public func play(_ sound: Sound) {
        guard enabled, let buffer = buffers[sound] else { return }
        // The "listening" chime would land in the recording through built-in speakers; skip it there.
        if sound == .listening, AudioDevices.defaultOutput()?.isBuiltIn == true { return }
        queue.async { [self] in
            generation += 1
            do {
                if !engine.isRunning { try engine.start() }
                player.scheduleBuffer(buffer, at: nil, options: .interrupts)
                if !player.isPlaying { player.play() }
                busyUntil = DispatchTime.now() + Double(buffer.frameLength) / format.sampleRate + 0.1
            } catch {
                Log.audio.error("earcon failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Releases the output device once the last sound has finished (so a sound is never cut off).
    public func idle() {
        queue.async { [self] in
            let expected = generation
            queue.asyncAfter(deadline: max(busyUntil, .now())) { [self] in
                guard generation == expected else { return } // a newer sound is playing
                player.stop()
                engine.stop()
            }
        }
    }

    /// Soft sine notes with a fast attack and exponential release (no clicks).
    private func render(notes: [(frequency: Double, duration: Double)], gain: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = notes.reduce(0) { $0 + $1.duration } + 0.04
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total * rate)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let data = buffer.floatChannelData![0]
        var cursor = 0
        for note in notes {
            let frames = Int(note.duration * rate)
            let tail = Int(0.04 * rate) // let each note ring out into the next
            for i in 0..<(frames + tail) where cursor + i < Int(buffer.frameLength) {
                let t = Double(i) / rate
                let attack = min(1, t / 0.006)
                let release = i < frames ? 1 : exp(-Double(i - frames) / (0.012 * rate))
                let env = Float(attack * release * exp(-t * 6))
                // Fundamental plus a quiet octave for a rounder, bell-like tone.
                let s = sin(2 * .pi * note.frequency * t) + 0.18 * sin(4 * .pi * note.frequency * t)
                data[cursor + i] += Float(s) * env * gain
            }
            cursor += frames
        }
        return buffer
    }
}
