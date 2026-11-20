// Grapheme-to-phoneme for Kokoro (no GPL components). Adapted from the Wisp Kokoro research harness.
import CoreML
import Foundation

/// English (en-US) grapheme-to-phoneme with NO GPL components:
///   1. small misaki-style function-word rules (a/an/the/to/in)
///   2. misaki gold lexicon, then silver lexicon (Apache-2.0 data files)
///   3. BART seq2seq G2P Core ML fallback for out-of-vocabulary words
/// Output is a misaki-style phoneme string (uses A/I/O/W/Y diphthong shorthand,
/// which is exactly Kokoro's input alphabet in vocab_index.json).
final class EnglishG2P: @unchecked Sendable {
    private let gold: [String: Any]
    private let silver: [String: Any]
    private let encoder: MLModel
    private let decoder: MLModel
    private let graphemeToId: [String: Int32]
    private let idToPhoneme: [Int: String]
    private let bos: Int32, eos: Int32, unk: Int32
    private(set) var bartCalls = 0

    init(directory: URL) throws {
        func json(_ name: String) throws -> Any {
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name)))
        }
        guard let gold = try json("us_gold.json") as? [String: Any],
              let silver = try json("us_silver.json") as? [String: Any],
              let vocab = try json("g2p_vocab.json") as? [String: Any],
              let g2i = vocab["grapheme_to_id"] as? [String: Int],
              let i2p = vocab["id_to_phoneme"] as? [String: String] else { throw KokoroError.badModelFiles }
        self.gold = gold
        self.silver = silver
        graphemeToId = g2i.mapValues(Int32.init)
        idToPhoneme = Dictionary(uniqueKeysWithValues: i2p.compactMap { k, v in Int(k).map { ($0, v) } })
        bos = Int32(vocab["bos_token_id"] as? Int ?? 1)
        eos = Int32(vocab["eos_token_id"] as? Int ?? 2)
        unk = graphemeToId["<unk>"] ?? 3
        // Autoregressive decoder with tiny steps: CPU is fastest (per FluidAudio benchmarks).
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        encoder = try MLModel(contentsOf: directory.appendingPathComponent("G2PEncoder.mlmodelc"), configuration: cfg)
        decoder = try MLModel(contentsOf: directory.appendingPathComponent("G2PDecoder.mlmodelc"), configuration: cfg)
    }

    // MARK: lexicon

    private func entry(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] {
            if let s = d["DEFAULT"] as? String { return s }
            return d.values.compactMap { $0 as? String }.first
        }
        return nil
    }

    private func lexicon(_ word: String) -> String? {
        let candidates = [word, word.lowercased(), word.capitalized]
        for c in candidates { if let p = entry(gold[c]) { return p } }
        for c in candidates { if let p = entry(silver[c]) { return p } }
        // simple plural / possessive fallback
        if word.lowercased().hasSuffix("'s"), let base = lexicon(String(word.dropLast(2))) {
            return base + (base.last.map { "ptkfθ".contains($0) } == true ? "s" : "z")
        }
        return nil
    }

    // MARK: BART fallback

    private func bart(_ word: String) throws -> String {
        bartCalls += 1
        var ids: [Int32] = [bos]
        for ch in word { ids.append(graphemeToId[String(ch)] ?? unk) }
        ids.append(eos)
        guard ids.count <= 64 else { return "" }
        let inp = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, v) in ids.enumerated() { inp[i] = NSNumber(value: v) }
        let enc = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": inp]))
        guard let hidden = enc.featureValue(for: "encoder_hidden_states")?.multiArrayValue else { return "" }
        // encoder_hidden_states is fp16 in the model; decoder wants fp32.
        let h32 = try MLMultiArray(shape: hidden.shape, dataType: .float32)
        for i in 0..<hidden.count { h32[i] = hidden[i] }

        var out: [Int32] = [bos]
        for _ in 0..<64 {
            let L = out.count
            let dec = try MLMultiArray(shape: [1, NSNumber(value: L)], dataType: .int32)
            let pos = try MLMultiArray(shape: [1, NSNumber(value: L)], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: L), NSNumber(value: L)], dataType: .float32)
            for i in 0..<L {
                dec[i] = NSNumber(value: out[i]); pos[i] = NSNumber(value: i + 2)  // BART learned positions are offset by 2
                for j in 0..<L { mask[i * L + j] = NSNumber(value: j <= i ? 0 : -1e4) }
            }
            let r = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "decoder_input_ids": dec, "encoder_hidden_states": h32, "position_ids": pos, "causal_mask": mask,
            ]))
            guard let logits = r.featureValue(for: "logits")?.multiArrayValue else { break }  // [1, L, V]
            let V = logits.shape[2].intValue
            // use strides: fp16 outputs can be padded, flat indexing is NOT safe
            let base = (L - 1) * logits.strides[1].intValue
            let vs = logits.strides[2].intValue
            var best = 0; var bestV = -Float.infinity
            for k in 0..<V { let v = logits[base + k * vs].floatValue; if v > bestV { bestV = v; best = k } }
            if Int32(best) == eos { break }
            out.append(Int32(best))
        }
        return out.dropFirst().compactMap { id -> String? in
            let s = idToPhoneme[Int(id)]
            return (s == nil || s!.hasPrefix("<")) ? nil : s
        }.joined()
    }

    // MARK: text -> phonemes

    private static let vowelStart = Set("AIOWYaeiouæɑɐɒɔəɚɛɜɪʊʌᵻᵊ".map { $0 })

    /// Very small text normaliser (the product should do real number/abbrev normalisation upstream).
    static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "\u{2013}", with: ", ").replacingOccurrences(of: "\u{2014}", with: ", ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func phonemize(_ text: String) throws -> String {
        // tokens: words (letters, digits, apostrophes, hyphens) and punctuation
        var tokens: [(text: String, isWord: Bool, spaceAfter: Bool)] = []
        var cur = ""
        let chars = Array(EnglishG2P.normalize(text))
        func flush(_ spaceAfter: Bool) { if !cur.isEmpty { tokens.append((cur, true, spaceAfter)); cur = "" } }
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber || ((c == "'" || c == "-") && !cur.isEmpty) {
                cur.append(c)
            } else if c.isWhitespace {
                flush(true); if let l = tokens.indices.last { tokens[l].spaceAfter = true }
            } else {
                flush(false)
                let p: String? = ",.!?;:".contains(c) ? String(c) : (c == "\"" ? "\u{201C}" : (c == "(" || c == ")" ? String(c) : nil))
                if let p { tokens.append((p, false, i + 1 < chars.count && chars[i + 1].isWhitespace)) }
            }
        }
        flush(false)

        // first pass: lexicon/BART per word
        var ph: [String] = try tokens.map { tok in
            guard tok.isWord else { return tok.text }
            let w = tok.text.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            switch w.lowercased() {
            case "a": return "ɐ"
            case "an": return "ɐn"
            case "the", "to", "in": return w.lowercased()  // resolved in pass 2
            default: break
            }
            if let p = lexicon(w) { return p }
            if w.contains("-") {
                return try w.split(separator: "-").map { try lexicon(String($0)) ?? bart(String($0).lowercased()) }.joined(separator: " ")
            }
            return try bart(w.lowercased())
        }
        // second pass: context-dependent function words
        for i in tokens.indices where tokens[i].isWord {
            let nextVowel: Bool? = (i + 1 < ph.count && tokens[i + 1].isWord) ? ph[i + 1].first.map { EnglishG2P.vowelStart.contains($0) } : nil
            switch ph[i] {
            case "the": ph[i] = nextVowel == true ? "ði" : "ðə"
            case "to": ph[i] = nextVowel == nil ? "tˈu" : (nextVowel! ? "tʊ" : "tə")
            case "in": ph[i] = nextVowel == nil ? "ˈɪn" : "ɪn"
            default: break
            }
        }
        var out = ""
        for (i, tok) in tokens.enumerated() {
            out += ph[i]
            if tok.spaceAfter { out += " " }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
