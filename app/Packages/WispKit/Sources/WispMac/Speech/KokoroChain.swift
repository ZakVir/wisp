// Kokoro-82M as a chain of seven Core ML stages (FluidInference/kokoro-82m-coreml "ANE" build, conversion by
// laishere/kokoro-coreml). The stage order, tensor names, fp16/fp32 boundaries and compute-unit routing are ported
// from FluidAudio's KokoroAneSynthesizer (Apache License 2.0, github.com/FluidInference/FluidAudio).
//
// Why not the single INT8 model: its 8-bit vocoder adds an audible grainy noise floor and its duration predictor
// speaks ~25% faster than upstream Kokoro (measured against hexgrad's PyTorch model from identical phonemes). This
// chain matches upstream in timing and harmonic structure.
import Accelerate
@preconcurrency import CoreML
import Foundation

final class KokoroChain: @unchecked Sendable {
    static let sampleRate = 24_000
    /// Longest phoneme string one call takes (the voice pack has a style row per length up to this).
    static let maxPhonemes = 510
    /// 2,000 acoustic frames × 600 samples = 50 s, far beyond one spoken sentence.
    static let maxFrames = 2_000

    enum Stage: String, CaseIterable {
        case albert = "KokoroAlbert"
        case postAlbert = "KokoroPostAlbert"
        case alignment = "KokoroAlignment"
        case prosody = "KokoroProsody_v2"   // fp32 compute: fp16 corrupted pitch at long utterances' onsets
        case noise = "KokoroNoise_v2"       // phase-corrected harmonic source (high-frequency noise fix)
        case vocoder = "KokoroVocoder"
        case tail = "KokoroTail_v2"         // COLA-normalized iSTFT (correct level)

        /// Neural Engine for the network stages; the all-fp32 noise source and iSTFT tail run on the GPU, except on
        /// macOS 27+, where FluidAudio moved them to the CPU after MPSGraph aborts.
        var computeUnits: MLComputeUnits {
            switch self {
            case .noise, .tail:
                return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? .cpuOnly : .cpuAndGPU
            default:
                return .cpuAndNeuralEngine
            }
        }
    }

    private let models: [Stage: MLModel]
    let vocab: [Character: Int32]

    init(directory: URL) throws {
        var loaded: [Stage: MLModel] = [:]
        for stage in Stage.allCases {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = stage.computeUnits
            cfg.allowLowPrecisionAccumulationOnGPU = true
            loaded[stage] = try MLModel(contentsOf: directory.appendingPathComponent("\(stage.rawValue).mlmodelc"),
                                        configuration: cfg)
        }
        models = loaded
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("vocab_index.json"))) as? [String: Any],
              let v = (obj["vocab"] as? [String: Int]) ?? (obj as? [String: Int]) else { throw KokoroError.badModelFiles }
        var m: [Character: Int32] = [:]
        for (k, id) in v { if let c = k.first, k.count == 1 { m[c] = Int32(id) } }
        vocab = m
    }

    /// Phoneme ids for `phonemes` (unknown symbols dropped), without the boundary tokens.
    func tokenIds(_ phonemes: String) -> [Int32] {
        phonemes.unicodeScalars.compactMap { vocab[Character($0)] }
    }

    /// One phoneme string (≤ 510) → 24 kHz mono samples. `style` is the voice pack row for this length:
    /// [0..<128] timbre (noise source and vocoder), [128..<256] prosody style.
    func synthesize(phonemeIds ids: [Int32], style: [Float], speed: Float = 1) throws -> [Float] {
        guard !ids.isEmpty, ids.count <= Self.maxPhonemes, style.count == 256 else { throw KokoroError.tooLong }
        let seq: [Int32] = [0] + ids + [0]
        let tokens = seq.count
        let inputIds = try Arrays.int32(shape: [1, tokens], from: seq)
        let mask = try Arrays.int32(shape: [1, tokens], from: [Int32](repeating: 1, count: tokens))
        let timbre = Array(style[0..<128]), prosodyStyle = Array(style[128..<256])
        let styleS = try Arrays.float16(shape: [1, 128], from: prosodyStyle)
        let timbre32 = try Arrays.float32(shape: [1, 128], from: timbre)
        let timbre16 = try Arrays.float16(shape: [1, 128], from: timbre)
        let speedArr = try Arrays.float16(shape: [1], from: [speed])

        let albert = try predict(.albert, ["input_ids": inputIds, "attention_mask": mask])
        let post = try predict(.postAlbert, ["bert_dur": try fp16(albert, "bert_dur"), "input_ids": inputIds,
                                             "style_s": styleS, "speed": speedArr, "attention_mask": mask])
        let durations = Arrays.floats(try output(post, "duration"))
        guard durations.allSatisfy(\.isFinite) else { throw KokoroError.badOutput }
        let predDur = durations.map { Int32(min(max($0.rounded(), 1), Float(Self.maxFrames))) }
        guard predDur.reduce(0, { $0 + Int($1) }) <= Self.maxFrames else { throw KokoroError.tooLong }

        let align = try predict(.alignment, ["pred_dur": try Arrays.int32(shape: [1, predDur.count], from: predDur),
                                             "d": try fp16(post, "d"), "t_en": try fp16(post, "t_en")])
        let prosody = try predict(.prosody, ["en": try fp16(align, "en"), "style_s": styleS])
        let f0 = try output(prosody, "F0"), n = try output(prosody, "N")
        let f0Shape = f0.shape.map(\.intValue), nShape = n.shape.map(\.intValue)

        let noise = try predict(.noise, ["F0_curve": try Arrays.float32(shape: f0Shape, from: f0), "style_timbre": timbre32])
        let vocoder = try predict(.vocoder, [
            "asr": try fp16(align, "asr"),
            "F0_curve": try Arrays.float16(shape: f0Shape, from: f0),
            "N_pred": try Arrays.float16(shape: nShape, from: n),
            "x_source_0": try fp16(noise, "x_source_0"),
            "x_source_1": try fp16(noise, "x_source_1"),
            "style_timbre": timbre16,
        ])
        let xPre = try output(vocoder, "x_pre")
        let tail = try predict(.tail, ["x_pre": try Arrays.float32(shape: xPre.shape.map(\.intValue), from: xPre)])
        return Arrays.floats(try output(tail, "audio"))
    }

    private func predict(_ stage: Stage, _ inputs: [String: MLMultiArray]) throws -> MLFeatureProvider {
        guard let model = models[stage] else { throw KokoroError.badModelFiles }
        return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) }))
    }

    private func output(_ provider: MLFeatureProvider, _ key: String) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: key)?.multiArrayValue else { throw KokoroError.badOutput }
        return value
    }

    private func fp16(_ provider: MLFeatureProvider, _ key: String) throws -> MLMultiArray {
        let value = try output(provider, key)
        return try Arrays.float16(shape: value.shape.map(\.intValue), from: value)
    }
}

/// MLMultiArray builders with fp16 ↔ fp32 conversion through vImage (ported from FluidAudio's KokoroAneArrays).
private enum Arrays {
    /// Slack after each buffer: some Core ML stages read slightly past the logical end.
    static let tailSlack = 16_384

    static func make(shape: [Int], type: MLMultiArrayDataType, elementSize: Int) throws -> MLMultiArray {
        let bytes = shape.reduce(1, *) * elementSize + tailSlack
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        var strides = [Int](repeating: 1, count: shape.count)
        for i in stride(from: shape.count - 2, through: 0, by: -1) { strides[i] = strides[i + 1] * shape[i + 1] }
        return try MLMultiArray(dataPointer: buffer, shape: shape.map { NSNumber(value: $0) }, dataType: type,
                                strides: strides.map { NSNumber(value: $0) }, deallocator: { $0.deallocate() })
    }

    static func int32(shape: [Int], from source: [Int32]) throws -> MLMultiArray {
        let arr = try make(shape: shape, type: .int32, elementSize: 4)
        source.withUnsafeBufferPointer { arr.dataPointer.bindMemory(to: Int32.self, capacity: source.count).update(from: $0.baseAddress!, count: source.count) }
        return arr
    }

    static func float32(shape: [Int], from source: [Float]) throws -> MLMultiArray {
        let arr = try make(shape: shape, type: .float32, elementSize: 4)
        source.withUnsafeBufferPointer { arr.dataPointer.bindMemory(to: Float.self, capacity: source.count).update(from: $0.baseAddress!, count: source.count) }
        return arr
    }

    static func float16(shape: [Int], from source: [Float]) throws -> MLMultiArray {
        let arr = try make(shape: shape, type: .float16, elementSize: 2)
        source.withUnsafeBufferPointer { src in
            f32to16(src.baseAddress!, arr.dataPointer.bindMemory(to: UInt16.self, capacity: source.count), source.count)
        }
        return arr
    }

    static func float16(shape: [Int], from source: MLMultiArray) throws -> MLMultiArray {
        let total = shape.reduce(1, *)
        let dst = try make(shape: shape, type: .float16, elementSize: 2)
        let out = dst.dataPointer.bindMemory(to: UInt16.self, capacity: total)
        if isContiguous(source), source.dataType == .float16 {
            memcpy(out, source.dataPointer, total * 2)
        } else if isContiguous(source), source.dataType == .float32 {
            f32to16(source.dataPointer.bindMemory(to: Float.self, capacity: total), out, total)
        } else {
            var tmp = [Float](repeating: 0, count: total)
            for i in 0..<total { tmp[i] = source[i].floatValue }
            tmp.withUnsafeBufferPointer { f32to16($0.baseAddress!, out, total) }
        }
        return dst
    }

    static func float32(shape: [Int], from source: MLMultiArray) throws -> MLMultiArray {
        let total = shape.reduce(1, *)
        let dst = try make(shape: shape, type: .float32, elementSize: 4)
        let out = dst.dataPointer.bindMemory(to: Float.self, capacity: total)
        if isContiguous(source), source.dataType == .float32 {
            memcpy(out, source.dataPointer, total * 4)
        } else if isContiguous(source), source.dataType == .float16 {
            f16to32(source.dataPointer.bindMemory(to: UInt16.self, capacity: total), out, total)
        } else {
            for i in 0..<total { out[i] = source[i].floatValue }
        }
        return dst
    }

    static func floats(_ arr: MLMultiArray) -> [Float] {
        let count = arr.count
        if isContiguous(arr), arr.dataType == .float32 {
            return Array(UnsafeBufferPointer(start: arr.dataPointer.bindMemory(to: Float.self, capacity: count), count: count))
        }
        if isContiguous(arr), arr.dataType == .float16 {
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBufferPointer { f16to32(arr.dataPointer.bindMemory(to: UInt16.self, capacity: count), $0.baseAddress!, count) }
            return out
        }
        return (0..<count).map { arr[$0].floatValue }
    }

    private static func isContiguous(_ arr: MLMultiArray) -> Bool {
        var expected = 1
        for (dim, stride) in zip(arr.shape.map(\.intValue).reversed(), arr.strides.map(\.intValue).reversed()) {
            if dim > 1, stride != expected { return false }
            expected *= max(dim, 1)
        }
        return true
    }

    private static func f32to16(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<UInt16>, _ count: Int) {
        var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        var d = vImage_Buffer(data: dst, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
    }

    private static func f16to32(_ src: UnsafePointer<UInt16>, _ dst: UnsafeMutablePointer<Float>, _ count: Int) {
        var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        var d = vImage_Buffer(data: dst, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
    }
}
