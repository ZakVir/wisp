import Foundation

/// Easing curves used by the companion's flights.
public enum Easing {
    /// Smooth start and end (cubic).
    public static func inOutCubic(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Fast start, gentle settle with a small overshoot (`overshoot` 0 = none, 1.70158 = classic "back").
    public static func outBack(_ t: Double, overshoot: Double = 0.9) -> Double {
        let x = min(max(t, 0), 1)
        let c3 = overshoot + 1
        return 1 + c3 * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
    }

    /// Smooth start, fast finish (for diving back into the menu bar).
    public static func inCubic(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * x
    }
}

/// A curved flight from one point to another (AppKit global coordinates, y up). The path is a quadratic
/// Bézier whose control point is pushed sideways, so motion arcs naturally instead of sliding in a line.
public struct FlightPath: Sendable, Equatable {
    public var start: Vec2
    public var end: Vec2
    /// Sideways bulge as a fraction of the distance (positive arcs to the left of the travel direction).
    public var arc: Double

    public init(start: Vec2, end: Vec2, arc: Double = 0.18) {
        self.start = start
        self.end = end
        self.arc = arc
    }

    public var distance: Double { start.distance(to: end) }

    private var control: Vec2 {
        let mid = start.lerp(to: end, 0.5)
        let d = end - start
        let len = max(d.length, 0.0001)
        let normal = Vec2(-d.y / len, d.x / len)
        return mid + normal * (len * arc)
    }

    public func point(at t: Double) -> Vec2 {
        let u = 1 - t
        let c = control
        return start * (u * u) + c * (2 * u * t) + end * (t * t)
    }

    /// Unit tangent (direction of travel) at `t`.
    public func direction(at t: Double) -> Vec2 {
        let c = control
        let d = (c - start) * (2 * (1 - t)) + (end - c) * (2 * t)
        let len = d.length
        return len > 0 ? d * (1 / len) : Vec2(1, 0)
    }

    /// Flight duration scaled by distance: short hops stay snappy, cross-screen flights stay readable.
    public static func duration(forDistance d: Double, minimum: Double = 0.28, maximum: Double = 0.75) -> Double {
        min(maximum, max(minimum, 0.22 + d / 2600))
    }
}
