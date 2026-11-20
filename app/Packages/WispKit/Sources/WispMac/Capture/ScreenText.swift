import CoreGraphics
import Foundation
import Vision
import WispCore

/// The text on a screenshot, found with Apple's on-device text recognition. Used to check that a point names
/// something that is really there ("First Aid" next to the point) before it is shown. Nothing leaves the Mac,
/// and the text is kept only for the turn.
public struct ScreenText: Sendable {
    public struct Line: Sendable {
        public var text: String
        /// Image pixels, top-left origin.
        public var rect: Rect
        /// Word-level boxes for the line, in reading order (same coordinates).
        public var words: [(text: String, rect: Rect)]
    }

    public var lines: [Line]
    public var size: PixelSize

    /// Recognizes the text on `image` (the pre-sized screenshot). ~0.3–1 s on Apple silicon; run it while the
    /// model is answering. Returns nil if recognition fails.
    public static func recognize(_ image: CGImage) -> ScreenText? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // UI labels aren't prose ("APFS", "Rand", "e")
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.006 // small toolbar labels on a 1456-px image
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let w = Double(image.width), h = Double(image.height)
        func rect(_ bb: CGRect) -> Rect {
            Rect(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h)
        }
        var lines: [Line] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var words: [(String, Rect)] = []
            var searchStart = text.startIndex
            for word in text.split(whereSeparator: \.isWhitespace) {
                guard let range = text.range(of: word, range: searchStart..<text.endIndex) else { continue }
                searchStart = range.upperBound
                if let box = try? candidate.boundingBox(for: range) {
                    words.append((String(word), rect(box.boundingBox)))
                }
            }
            lines.append(Line(text: text, rect: rect(observation.boundingBox), words: words))
        }
        return ScreenText(lines: lines, size: PixelSize(width: image.width, height: image.height))
    }

    /// All readable text on `image`, top to bottom and left to right, for copying (prose settings: language
    /// correction on, any language). Lines starting within `skipTop` pixels of the top (the menu bar) are left out.
    public static func readableText(_ image: CGImage, skipTop: Double = 0) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // The Mac's own languages (auto-detection reads symbols like "×" as other alphabets).
        var languages = Array(Locale.preferredLanguages.prefix(3))
        if !languages.contains(where: { $0.hasPrefix("en") }) { languages.append("en-US") }
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let h = Double(image.height)
        var lines: [(y: Double, x: Double, height: Double, text: String)] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let top = (1 - observation.boundingBox.maxY) * h
            if top < skipTop { continue }
            lines.append((top, observation.boundingBox.minX, observation.boundingBox.height * h, text))
        }
        // Reading order: rows (lines whose tops are within half a line of each other), each left to right.
        lines.sort { $0.y < $1.y }
        var rows: [[(y: Double, x: Double, height: Double, text: String)]] = []
        for line in lines {
            if let last = rows.last?.first, abs(line.y - last.y) < max(4, last.height / 2) { rows[rows.count - 1].append(line) }
            else { rows.append([line]) }
        }
        let text = rows.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: "    ") }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Vision loads and compiles its text model on first use (tens of seconds on some Macs); do that at launch, off the
    /// main thread, so the first question's OCR is instant.
    public static func warmUp() {
        Task.detached(priority: .utility) {
            guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = ctx.makeImage() else { return }
            let start = ProcessInfo.processInfo.systemUptime
            _ = recognize(image)
            Log.capture.info("screen text recognition ready in \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000), privacy: .public) ms")
        }
    }

    /// Letters and digits only, lowercased: "First Aid…" and "first aid" compare equal.
    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Every place `label` appears on screen: a run of consecutive words on one line whose tokens match the
    /// label's tokens (so "Export button" matches the word "Export", and "First Aid" matches those two words).
    public func matches(label: String) -> [Rect] {
        var wanted = Self.tokens(label)
        // Trailing words that describe the control, not its name.
        let kinds: Set<String> = ["button", "icon", "menu", "item", "tab", "link", "field", "option", "checkbox", "toggle", "key"]
        while wanted.count > 1, let last = wanted.last, kinds.contains(last) { wanted.removeLast() }
        guard !wanted.isEmpty, wanted.joined().count >= 2 else { return [] }
        var found: [Rect] = []
        for line in lines {
            let lineTokens = line.words.map { Self.tokens($0.text).joined() }
            guard lineTokens.count >= wanted.count else { continue }
            for start in 0...(lineTokens.count - wanted.count) {
                var ok = true
                for (k, want) in wanted.enumerated() where lineTokens[start + k] != want { ok = false; break }
                guard ok else { continue }
                let boxes = line.words[start..<(start + wanted.count)].map(\.rect)
                let minX = boxes.map(\.minX).min()!, minY = boxes.map(\.minY).min()!
                let maxX = boxes.map(\.maxX).max()!, maxY = boxes.map(\.maxY).max()!
                found.append(Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
        }
        return found
    }

    /// The occurrence of `label` nearest to `point` (image pixels) if it is within `maxDistance` of it, measured
    /// from the point to the nearest edge of the text's box.
    public func box(for label: String, near point: Vec2, maxDistance: Double) -> Rect? {
        var best: (Rect, Double)?
        for rect in matches(label: label) {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= maxDistance, best == nil || d < best!.1 { best = (rect, d) }
        }
        return best?.0
    }
}
