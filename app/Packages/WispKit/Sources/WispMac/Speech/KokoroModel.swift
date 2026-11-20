// Kokoro voice packs, text chunking and errors (the model itself is KokoroChain).
import CoreML
import Foundation

/// Voice style source.
enum KokoroVoice {
    /// aufklarer voices/<name>.json: {"embedding":[256]} — this is the MEAN of the 510 rows of the upstream pack.
    case mean([Float])
    /// Upstream-faithful pack [510,256] (raw little-endian fp32, e.g. FluidInference ANE/af_heart.bin,
    /// byte-identical to hexgrad voices/af_heart.pt data); row = phonemeCount - 1.
    case pack([Float])

    static func load(_ url: URL) throws -> KokoroVoice {
        if url.pathExtension == "json" {
            guard let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw KokoroError.badModelFiles }
            // FluidInference voices/<name>.json: the full pack as rows "1"..."510" (plus a mean "embedding").
            if o["1"] != nil {
                var pack: [Float] = []
                pack.reserveCapacity(510 * 256)
                for row in 1...510 {
                    guard let r = o[String(row)] as? [Double], r.count == 256 else { throw KokoroError.badModelFiles }
                    pack += r.map(Float.init)
                }
                return .pack(pack)
            }
            guard let e = o["embedding"] as? [Double], e.count >= 256 else { throw KokoroError.badModelFiles }
            return .mean(e.prefix(256).map(Float.init))
        }
        let d = try Data(contentsOf: url)
        guard d.count == 510 * 256 * 4 else { throw KokoroError.badModelFiles }
        return .pack(d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
    }

    func style(phonemeCount: Int) -> [Float] {
        switch self {
        case .mean(let v): return v
        case .pack(let p):
            let row = min(max(phonemeCount - 1, 0), 509)
            return Array(p[(row * 256)..<(row * 256 + 256)])
        }
    }
}

/// Splits text into sentence-sized chunks that fit the 126-phoneme / 5-second window.
enum Chunker {
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        return out.isEmpty ? [text] : out
    }

    /// Split a phoneme string at the best boundary (punctuation, else space) near the middle.
    static func split(_ ph: String) -> (String, String) {
        let chars = Array(ph)
        let mid = chars.count / 2
        var best: Int? = nil
        for (i, c) in chars.enumerated() where ",;:.!?".contains(c) {
            if best == nil || abs(i - mid) < abs(best! - mid) { best = i }
        }
        if best == nil || abs(best! - mid) > chars.count / 3 {
            for (i, c) in chars.enumerated() where c == " " {
                if best == nil || abs(i - mid) < abs(best! - mid) { best = i }
            }
        }
        let cut = (best ?? mid) + 1
        return (String(chars[..<cut]).trimmingCharacters(in: .whitespaces),
                String(chars[cut...]).trimmingCharacters(in: .whitespaces))
    }
}

enum KokoroError: Error {
    case badModelFiles, tooLong, badOutput
}
