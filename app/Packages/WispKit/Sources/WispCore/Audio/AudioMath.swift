import Foundation

/// Small, testable audio helpers.
public enum AudioMath {
    /// Root-mean-square of `samples` in decibels relative to full scale (0 dBFS = 1.0). Silence → -160.
    public static func rmsDBFS(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -160 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    public static func rmsDBFS(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rmsDBFS($0) }
    }

    /// Maps dBFS to a 0...1 meter value with a floor (default -55 dB) so normal speech fills the meter.
    public static func meterLevel(dbfs: Float, floor: Float = -55, ceiling: Float = -8) -> Float {
        guard dbfs > floor else { return 0 }
        return min(1, (dbfs - floor) / (ceiling - floor))
    }

    /// Exponential smoothing for meters: fast attack, slower release, so speech looks lively but not jittery.
    public static func smooth(previous: Float, next: Float, attack: Float = 0.6, release: Float = 0.15) -> Float {
        let k = next > previous ? attack : release
        return previous + (next - previous) * k
    }
}

/// A finished recording, in memory only (never written to disk).
public struct Utterance: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Seconds from key-down to the first microphone buffer.
    public var firstBufferLatency: TimeInterval?
    public var peakDBFS: Float

    public init(samples: [Float], sampleRate: Double, firstBufferLatency: TimeInterval?, peakDBFS: Float) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.firstBufferLatency = firstBufferLatency
        self.peakDBFS = peakDBFS
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }

    /// True when nothing above the noise floor was captured (e.g. a muted or broken microphone).
    public var isSilent: Bool { peakDBFS < -60 }
}
