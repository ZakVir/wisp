import Foundation
import WispCore

/// Appends each turn's stage timings to `~/Library/Application Support/Wisp/timings.jsonl` when the user allows
/// local timing logs. Only numbers, model id and an outcome code; never what was said or seen.
public final class TimingLog: @unchecked Sendable {
    public static let shared = TimingLog()
    public var enabled = true
    private let queue = DispatchQueue(label: "com.zakvirani.wisp.timing")
    public var url: URL { AppPaths.applicationSupport.appendingPathComponent("timings.jsonl") }

    public func record(_ timing: TurnTiming) {
        let summary = timing.summary.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        Log.timing.info("turn \(timing.outcome, privacy: .public) model=\(timing.model ?? "-", privacy: .public) tts=\(timing.ttsEngine ?? "-", privacy: .public) \(summary, privacy: .public)")
        guard enabled else { return }
        queue.async { [url] in
            guard var data = try? JSONEncoder().encode(timing) else { return }
            data.append(0x0A)
            // Keep the file small: start over beyond 2 MB (about 5,000 turns).
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data) // throws (no crash) on a full disk
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                Log.timing.error("timing log write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Turning the setting off deletes what was recorded.
    public func setEnabled(_ on: Bool) {
        enabled = on
        if !on { queue.async { [url] in try? FileManager.default.removeItem(at: url) } }
    }

    public func load() -> [TurnTiming] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(TurnTiming.self, from: Data($0.utf8)) }
    }
}
