import CoreGraphics
import Foundation

/// The companion's silhouettes, drawn in a unit "canvas" (0...1 on both axes, y pointing down). Both shapes
/// put their hotspot (arrow tip / fingertip) at the same canvas point so they can morph into each other.
enum CompanionShapes {
    /// Hotspot in canvas units (y down).
    static let hotspot = CGPoint(x: 0.27, y: 0.13)
    /// Height of the arrow in canvas units (the rest is room for the 3D edge, shadow and glow).
    static let arrowHeight: CGFloat = 0.62
    static let handHeight: CGFloat = 0.66

    /// Classic arrow pointer (the user's reference): vertical left edge, long hypotenuse to the right
    /// corner, a flat underside back to the notch, and a tail down to the bottom point. All corners rounded.
    static func arrow() -> (fill: CGPath, details: CGPath?) {
        let h = arrowHeight
        let o = hotspot
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * h, y: o.y + y * h) }
        let pts = [p(0, 0), p(0.763, 0.644), p(0.295, 0.644), p(0, 1.0)]
        let radii: [CGFloat] = [0.05, 0.065, 0.035, 0.055].map { $0 * h }
        return (roundedPolygon(pts, radii: radii), nil)
    }

    /// Pointing hand: long index finger, rounded mitten-like palm with gently bumped folded fingers, and a
    /// thumb lobe that flows into the palm on the lower left.
    static func hand() -> (fill: CGPath, details: CGPath?) {
        let h = handHeight
        let o = hotspot
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * h, y: o.y + y * h) }
        let path = CGMutablePath()
        // Index finger (fully rounded top).
        path.addRoundedRect(in: CGRect(x: o.x - 0.088 * h, y: o.y, width: 0.176 * h, height: 0.66 * h),
                            cornerWidth: 0.088 * h, cornerHeight: 0.088 * h)
        // Palm: a smooth closed curve, flat-ish top under the folded fingers, deep round bottom.
        let palm = CGMutablePath()
        palm.move(to: pt(-0.088, 0.40))
        palm.addLine(to: pt(0.50, 0.40))
        palm.addCurve(to: pt(0.62, 0.62), control1: pt(0.60, 0.40), control2: pt(0.62, 0.50))
        palm.addCurve(to: pt(0.18, 1.0), control1: pt(0.62, 0.86), control2: pt(0.44, 1.0))
        palm.addCurve(to: pt(-0.22, 0.84), control1: pt(0.02, 1.0), control2: pt(-0.12, 0.95))
        palm.addLine(to: pt(-0.088, 0.62))
        palm.closeSubpath()
        path.addPath(palm)
        // Folded fingers: soft bumps along the top of the palm.
        for (cx, cy, rad) in [(0.17, 0.42, 0.10), (0.335, 0.43, 0.10), (0.49, 0.46, 0.095)] as [(CGFloat, CGFloat, CGFloat)] {
            path.addEllipse(in: CGRect(x: o.x + (cx - rad) * h, y: o.y + (cy - rad) * h, width: 2 * rad * h, height: 2 * rad * h))
        }
        // Thumb: a rounded lobe pointing up-left that merges into the palm.
        let thumb = CGMutablePath()
        let tr = CGRect(x: o.x - 0.34 * h, y: o.y + 0.58 * h, width: 0.36 * h, height: 0.19 * h)
        thumb.addRoundedRect(in: tr, cornerWidth: 0.095 * h, cornerHeight: 0.095 * h)
        var t = CGAffineTransform(translationX: tr.maxX, y: tr.midY).rotated(by: 0.78).translatedBy(x: -tr.maxX, y: -tr.midY)
        if let rotated = thumb.copy(using: &t) { path.addPath(rotated) }

        // Creases: index finger against the folded fingers, and between the folded fingers.
        let details = CGMutablePath()
        details.move(to: pt(0.088, 0.40)); details.addLine(to: pt(0.088, 0.60))
        details.move(to: pt(0.255, 0.40)); details.addLine(to: pt(0.255, 0.50))
        details.move(to: pt(0.415, 0.42)); details.addLine(to: pt(0.415, 0.52))
        return (path, details)
    }

    /// A polygon whose corners are rounded with per-corner radii.
    static func roundedPolygon(_ pts: [CGPoint], radii: [CGFloat]) -> CGPath {
        let path = CGMutablePath()
        let n = pts.count
        let start = CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2)
        path.move(to: start)
        for i in 0..<n {
            path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: radii[i])
        }
        path.closeSubpath()
        return path
    }

    /// Rounded rect with individual radii (topLeft, topRight, bottomRight, bottomLeft) in y-down space.
    static func roundedRect(_ r: CGRect, radii: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGPath {
        roundedPolygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)],
                       radii: [radii.0, radii.1, radii.2, radii.3])
    }
}

/// Signed distance fields for shapes, used by the companion shader for crisp edges at any size,
/// a 3D extruded edge, bevel lighting, soft shadows and arrow ↔ hand morphing.
enum ShapeSDF {
    /// Returns interleaved (signed distance to the fill, distance to detail lines) pairs for an N×N grid,
    /// in canvas units (negative inside the fill). Row 0 is the top of the canvas.
    static func make(fill: CGPath, details: CGPath?, size n: Int = 320) -> [Float] {
        let coverage = rasterize(n: n) { ctx in
            ctx.addPath(fill)
            ctx.fillPath()
        }
        let inside = coverage.map { $0 >= 0.5 }
        let distOut = edt(n: n, seeds: inside)               // distance from outside pixels to the shape
        let distIn = edt(n: n, seeds: inside.map { !$0 })    // distance from inside pixels to the outside
        var lineDist = [Float](repeating: 1, count: n * n)
        if let details {
            let lines = rasterize(n: n) { ctx in
                ctx.setLineWidth(0.006) // canvas units (the context is scaled to the canvas)
                ctx.setLineCap(.round)
                ctx.addPath(details)
                ctx.strokePath()
            }
            let d = edt(n: n, seeds: lines.map { $0 >= 0.5 })
            lineDist = d.map { $0 / Float(n) }
        }
        var out = [Float](repeating: 0, count: n * n * 2)
        for i in 0..<(n * n) {
            // Sub-pixel refinement from antialiased coverage keeps edges smooth when magnified.
            let c = coverage[i]
            // Boundary pixel with coverage c: the edge is (c - 0.5) px from its centre.
            let signed: Float = inside[i] ? -(distIn[i] - 1.5 + c) : (distOut[i] - 0.5 - c)
            out[i * 2] = signed / Float(n)
            out[i * 2 + 1] = lineDist[i]
        }
        return out
    }

    /// Antialiased coverage (0...1) of whatever `draw` paints, sampled on an N×N grid in canvas units.
    private static func rasterize(n: Int, draw: (CGContext) -> Void) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: n * n)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Canvas units (0...1, y down) → pixels; CGContext's origin is bottom-left, so flip.
            ctx.translateBy(x: 0, y: CGFloat(n))
            ctx.scaleBy(x: CGFloat(n), y: -CGFloat(n))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setShouldAntialias(true)
            draw(ctx)
        }
        return bytes.map { Float($0) / 255 }
    }

    /// Euclidean distance transform (Felzenszwalb & Huttenlocher): distance in pixels from every cell to the
    /// nearest seed cell.
    static func edt(n: Int, seeds: [Bool]) -> [Float] {
        let inf: Float = 1e20
        var grid = seeds.map { $0 ? Float(0) : inf }
        var f = [Float](repeating: 0, count: n)
        var d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Float](repeating: 0, count: n + 1)
        func transform1D() {
            var k = 0
            v[0] = 0
            z[0] = -inf
            z[1] = inf
            if n > 1 {
                for q in 1..<n {
                    var s = ((f[q] + Float(q * q)) - (f[v[k]] + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
                    while s <= z[k] {
                        k -= 1
                        s = ((f[q] + Float(q * q)) - (f[v[k]] + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
                    }
                    k += 1
                    v[k] = q
                    z[k] = s
                    z[k + 1] = inf
                }
            }
            k = 0
            for q in 0..<n {
                while z[k + 1] < Float(q) { k += 1 }
                let dq = Float(q - v[k])
                d[q] = dq * dq + f[v[k]]
            }
        }
        for x in 0..<n {
            for y in 0..<n { f[y] = grid[y * n + x] }
            transform1D()
            for y in 0..<n { grid[y * n + x] = d[y] }
        }
        for y in 0..<n {
            for x in 0..<n { f[x] = grid[y * n + x] }
            transform1D()
            for x in 0..<n { grid[y * n + x] = d[x].squareRoot() }
        }
        return grid
    }
}
