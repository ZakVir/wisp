import Foundation
import ImageIO
import WispCore

/// Finds a photo's main colours for a custom companion skin. The photo is read once, shrunk in memory and
/// forgotten; only the colours are kept.
enum PaletteExtractor {
    /// Big enough for any phone photo or wallpaper (HEIC, JPEG, PNG, TIFF…).
    static let maxFileBytes = 50 * 1024 * 1024

    enum Failure: Error, Equatable {
        case tooLarge, unreadable
        var message: String {
            switch self {
            case .tooLarge: return "That file is over 50 MB. Choose a smaller photo."
            case .unreadable: return "Wisp couldn't read that file as a photo."
            }
        }
    }

    static func colors(from url: URL, count: Int = 5) throws -> [RGB] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { throw Failure.unreadable }
        return colors(in: thumb, count: count)
    }

    /// k-means over the pixels, then the most vivid, distinct clusters (a big grey sky shouldn't win over the one
    /// red balloon, but a red balloon that's three pixels shouldn't either).
    static func colors(in image: CGImage, count: Int) -> [RGB] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var pixels: [RGB] = []
        pixels.reserveCapacity(w * h)
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 200 {
            pixels.append(RGB(Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255))
        }
        guard !pixels.isEmpty else { return [] }

        // k-means, seeded deterministically across the brightness range so the same photo gives the same skin.
        let k = min(10, pixels.count)
        let byLuma = pixels.sorted { $0.luminance < $1.luminance }
        var centers = (0..<k).map { byLuma[min(byLuma.count - 1, ($0 * 2 + 1) * byLuma.count / (2 * k))] }
        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<12 {
            for (i, p) in pixels.enumerated() {
                var best = 0, bestD = Double.infinity
                for (j, c) in centers.enumerated() {
                    let d = p.distance(to: c)
                    if d < bestD { bestD = d; best = j }
                }
                assignment[i] = best
            }
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: k)
            for (i, p) in pixels.enumerated() {
                let j = assignment[i]
                sums[j] = (sums[j].0 + p.r, sums[j].1 + p.g, sums[j].2 + p.b, sums[j].3 + 1)
            }
            for j in 0..<k where sums[j].3 > 0 {
                let n = Double(sums[j].3)
                centers[j] = RGB(sums[j].0 / n, sums[j].1 / n, sums[j].2 / n)
            }
        }
        var sizes = [Int](repeating: 0, count: k)
        for j in assignment { sizes[j] += 1 }
        let total = Double(pixels.count)
        let ranked = (0..<k).filter { Double(sizes[$0]) / total > 0.01 }.sorted { a, b in
            score(centers[a], share: Double(sizes[a]) / total) > score(centers[b], share: Double(sizes[b]) / total)
        }
        var chosen: [RGB] = []
        for j in ranked where chosen.allSatisfy({ $0.distance(to: centers[j]) > 0.18 }) {
            chosen.append(centers[j])
            if chosen.count == count { break }
        }
        return chosen.sorted { $0.luminance < $1.luminance }
    }

    private static func score(_ c: RGB, share: Double) -> Double {
        share.squareRoot() * (0.35 + c.saturation)
    }
}
