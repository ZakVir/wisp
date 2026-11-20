import Foundation

/// Something the companion does on screen while answering. All coordinates are AppKit global points (y up).
public enum Gesture: Equatable, Sendable {
    /// Fly to a point and highlight it.
    case point(at: Vec2, label: String)
    /// Trace a path with the cursor tip, leaving ink behind it (circles, underlines, arrows, freehand).
    case trace(TracePath, label: String)
}

/// A pen path the cursor follows at an even speed, parametrised by arc length.
public struct TracePath: Equatable, Sendable {
    public enum Kind: String, Sendable { case circle, underline, arrow, freehand }
    public var kind: Kind
    public var points: [Vec2]
    /// Seconds to draw it (scaled by length so small marks are quick and big ones stay readable).
    public var duration: Double
    private var cumulative: [Double]

    public init(kind: Kind, points: [Vec2], duration: Double? = nil) {
        self.kind = kind
        self.points = points.count >= 2 ? points : points + points
        var acc = [0.0]
        for i in 1..<self.points.count { acc.append(acc[i - 1] + self.points[i].distance(to: self.points[i - 1])) }
        cumulative = acc
        self.duration = duration ?? TracePath.duration(forLength: acc.last ?? 0)
    }

    public var length: Double { cumulative.last ?? 0 }
    public var start: Vec2 { points[0] }

    /// Pen speed: ~650 pt/s, between 0.45 s and 1.6 s.
    public static func duration(forLength length: Double) -> Double {
        min(1.6, max(0.45, length / 650))
    }

    /// The point a fraction `f` (0...1) of the way along the path.
    public func point(atFraction f: Double) -> Vec2 {
        let target = min(max(f, 0), 1) * length
        guard length > 0 else { return points[0] }
        var lo = 0, hi = cumulative.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= target { lo = mid } else { hi = mid }
        }
        let segment = cumulative[hi] - cumulative[lo]
        let t = segment > 0 ? (target - cumulative[lo]) / segment : 0
        return points[lo].lerp(to: points[hi], t)
    }

    /// The drawn part of the path up to fraction `f` (ending exactly at the pen tip).
    public func prefix(_ f: Double) -> [Vec2] {
        let target = min(max(f, 0), 1) * length
        var out: [Vec2] = [points[0]]
        for i in 1..<points.count {
            if cumulative[i] <= target { out.append(points[i]) } else { break }
        }
        let tip = point(atFraction: f)
        if out.last != tip { out.append(tip) }
        return out
    }

    /// Direction of travel at fraction `f` (unit vector).
    public func direction(atFraction f: Double) -> Vec2 {
        let a = point(atFraction: max(0, f - 0.01)), b = point(atFraction: min(1, f + 0.01))
        let d = b - a
        let len = d.length
        return len > 0 ? d * (1 / len) : Vec2(1, 0)
    }
}

/// Turns the model's shapes into hand-drawn-looking pen paths.
public enum GesturePlanner {
    /// A loose, slightly imperfect ellipse around `rect`, starting upper-left and overlapping its start a little,
    /// the way a person circles something with a pen.
    public static func circle(around rect: Rect, padding: Double = 10, seed: Int = 0) -> TracePath {
        let cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2
        // An ellipse must be ~√2 larger than the rect's half-sizes to pass outside its corners (1.48 leaves room
        // for the hand-drawn wobble), plus a little padding.
        let rx = max(rect.width / 2 * 1.48 + padding * 0.5, 18), ry = max(rect.height / 2 * 1.48 + padding * 0.5, 14)
        let startAngle = Double.pi * 0.82            // upper-left (y up)
        let sweep = -Double.pi * 2.12               // clockwise on screen, overlapping ~20°
        let steps = 72
        var pts: [Vec2] = []
        let phase = Double(seed % 7) * 0.9
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let a = startAngle + sweep * t
            // Gentle radius wobble + a slight spiral so the end doesn't land exactly on the start.
            let wobble = 1 + 0.035 * sin(3 * a + phase) + 0.05 * t
            pts.append(Vec2(cx + cos(a) * rx * wobble, cy + sin(a) * ry * wobble))
        }
        return TracePath(kind: .circle, points: pts)
    }

    /// A slightly curved line under something, from left to right.
    public static func underline(from a: Vec2, to b: Vec2) -> TracePath {
        let (l, r) = a.x <= b.x ? (a, b) : (b, a)
        let steps = 24
        var pts: [Vec2] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let p = l.lerp(to: r, t)
            pts.append(Vec2(p.x, p.y - 2.5 * sin(Double.pi * t))) // sags a touch, like a real pen stroke
        }
        return TracePath(kind: .underline, points: pts)
    }

    /// An arrow from `a` to `b`: a gently curved shaft, then the two head strokes.
    public static func arrow(from a: Vec2, to b: Vec2) -> TracePath {
        let d = b - a
        let len = max(d.length, 1)
        let dir = d * (1 / len)
        let normal = Vec2(-dir.y, dir.x)
        var pts: [Vec2] = []
        let steps = 28
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            pts.append(a.lerp(to: b, t) + normal * (len * 0.06 * sin(Double.pi * t)))
        }
        let head = min(18, len * 0.3)
        let back = b - dir * head
        pts.append(back + normal * (head * 0.55))
        pts.append(b)
        pts.append(back - normal * (head * 0.55))
        return TracePath(kind: .arrow, points: pts)
    }

    /// A smooth curve through the given points (Catmull-Rom), for freehand marks.
    public static func freehand(through points: [Vec2]) -> TracePath {
        guard points.count >= 3 else { return TracePath(kind: .freehand, points: points) }
        var out: [Vec2] = []
        let p = [points[0]] + points + [points[points.count - 1]]
        for i in 1..<(p.count - 2) {
            for s in 0..<8 {
                let t = Double(s) / 8
                let t2 = t * t, t3 = t2 * t
                func c(_ a: Double, _ b: Double, _ cc: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
                }
                out.append(Vec2(c(p[i - 1].x, p[i].x, p[i + 1].x, p[i + 2].x), c(p[i - 1].y, p[i].y, p[i + 1].y, p[i + 2].y)))
            }
        }
        out.append(points[points.count - 1])
        // Freehand strokes are drawings: drawn at a pace you can watch.
        let length = TracePath(kind: .freehand, points: out).length
        return TracePath(kind: .freehand, points: out, duration: Drawing.duration(forLength: length))
    }

    /// Maps a model event to a gesture on screen, or nil if its coordinates aren't usable.
    public static func gesture(for event: AssistantEvent, record: CaptureRecord, space: ModelCoordinateSpace, seed: Int = 0) -> Gesture? {
        func valid(_ x: Double, _ y: Double) -> Bool { record.isInRange(x, y, space: space) }
        switch event {
        case .say, .topic, .steps:
            return nil
        case .onScreen(_, let inner):
            // The caller picks the right screenshot record; map the inner event against it.
            return gesture(for: inner, record: record, space: space, seed: seed)
        case .point(let x, let y, let label):
            guard valid(x, y), let p = record.globalPoint(fromModel: x, y, space: space) else { return nil }
            return .point(at: p, label: label)
        case .circle(let x, let y, let w, let h, let label):
            guard valid(x, y), valid(x + w, y + h), w > 0, h > 0,
                  let r = record.globalRect(fromModel: x, y, width: w, height: h, space: space) else { return nil }
            return .trace(circle(around: r, seed: seed), label: label)
        case .underline(let x1, let y1, let x2, let y2, let label):
            guard valid(x1, y1), valid(x2, y2), let a = record.globalPoint(fromModel: x1, y1, space: space),
                  let b = record.globalPoint(fromModel: x2, y2, space: space) else { return nil }
            return .trace(underline(from: a, to: b), label: label)
        case .arrow(let x1, let y1, let x2, let y2, let label):
            guard valid(x1, y1), valid(x2, y2), let a = record.globalPoint(fromModel: x1, y1, space: space),
                  let b = record.globalPoint(fromModel: x2, y2, space: space), a.distance(to: b) > 8 else { return nil }
            return .trace(arrow(from: a, to: b), label: label)
        case .path(let pts, let label):
            let mapped = pts.filter { valid($0.x, $0.y) }.compactMap { record.globalPoint(fromModel: $0.x, $0.y, space: space) }
            guard mapped.count >= 2 else { return nil }
            return .trace(freehand(through: mapped), label: label)
        }
    }
}
