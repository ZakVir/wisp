import Foundation

/// One labelled screenshot of the pointing golden set (see tools/make_pointing_set.py).
public struct PointingGoldenItem: Codable, Sendable {
    public var id: String
    public var image: String
    public var question: String
    public var label: String
    /// Target box in image pixels: x0, y0, x1, y1 (y down).
    public var target: [Double]
    public var kind: String
    public var aspect: String
}

/// Scores where a model pointed against a known target box.
public enum PointingScore {
    /// The spot the companion would fly to for the first visual event, in image pixels (y down).
    public static func aimPoint(of events: [AssistantEvent], space: ModelCoordinateSpace, imageSize: PixelSize) -> Vec2? {
        for event in events {
            if let p = aim(event) { return toPixels(p, space: space, size: imageSize) }
        }
        return nil
    }

    static func aim(_ event: AssistantEvent) -> Vec2? {
        switch event {
        case .say, .topic, .steps: return nil
        case .onScreen(_, let inner): return aim(inner)
        case .point(let x, let y, _): return Vec2(x, y)
        case .circle(let x, let y, let w, let h, _): return Vec2(x + w / 2, y + h / 2)
        case .underline(let x1, let y1, let x2, let y2, _): return Vec2((x1 + x2) / 2, (y1 + y2) / 2)
        case .arrow(_, _, let x2, let y2, _): return Vec2(x2, y2)
        case .path(let pts, _): return pts.last
        }
    }

    static func toPixels(_ p: Vec2, space: ModelCoordinateSpace, size: PixelSize) -> Vec2 {
        switch space {
        case .imagePixels: return p
        case .normalized1000: return Vec2(p.x / 1000 * Double(size.width), p.y / 1000 * Double(size.height))
        case .normalizedUnit: return Vec2(p.x * Double(size.width), p.y * Double(size.height))
        }
    }

    /// Distance in pixels from `p` to the box (0 when inside).
    public static func distance(from p: Vec2, toBox b: [Double]) -> Double {
        guard b.count == 4 else { return .infinity }
        let dx = max(b[0] - p.x, 0, p.x - b[2])
        let dy = max(b[1] - p.y, 0, p.y - b[3])
        return (dx * dx + dy * dy).squareRoot()
    }

    /// A hit is inside the box, allowing `tolerance` pixels (the companion's tip and ring are bigger than that).
    public static func isHit(_ p: Vec2, box: [Double], tolerance: Double = 6) -> Bool {
        distance(from: p, toBox: box) <= tolerance
    }
}
