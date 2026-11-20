import Foundation

/// A 2D point independent of AppKit/CoreGraphics so motion math can be unit-tested anywhere.
public struct Vec2: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to other: Vec2) -> Double { (self - other).length }
    public func lerp(to other: Vec2, _ t: Double) -> Vec2 { self + (other - self) * t }
}

/// A damped spring that chases a target. Parameterized by response (seconds, roughly the time to settle)
/// and damping ratio (1 = critically damped, < 1 = slight overshoot), like SwiftUI's springs.
public struct Spring2D: Sendable {
    public var position: Vec2
    public var velocity: Vec2 = .zero
    public var response: Double
    public var dampingRatio: Double

    public init(position: Vec2, response: Double = 0.18, dampingRatio: Double = 0.9) {
        self.position = position
        self.response = response
        self.dampingRatio = dampingRatio
    }

    private var stiffness: Double { let w = 2 * Double.pi / max(response, 0.001); return w * w }
    private var damping: Double { 4 * Double.pi * dampingRatio / max(response, 0.001) }

    /// Advances by `dt` seconds toward `target`, sub-stepping for stability at low frame rates.
    public mutating func step(dt: Double, target: Vec2) {
        let steps = max(1, Int((dt / (1.0 / 240.0)).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let displacement = position - target
            let accel = displacement * -stiffness - velocity * damping
            velocity = velocity + accel * h
            position = position + velocity * h
        }
    }

    /// True when close enough to `target` and slow enough to stop animating.
    public func isSettled(at target: Vec2, tolerance: Double = 0.25) -> Bool {
        position.distance(to: target) < tolerance && velocity.length < tolerance * 10
    }

    /// Jumps to `target` with no motion (e.g. Reduce Motion, or first appearance).
    public mutating func snap(to target: Vec2) {
        position = target
        velocity = .zero
    }
}
