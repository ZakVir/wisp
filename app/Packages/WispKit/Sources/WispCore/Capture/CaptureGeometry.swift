import Foundation

/// A rectangle in AppKit global coordinates: points, origin at the bottom-left of the primary display,
/// y growing upwards. (Kept independent of CoreGraphics so the math is testable anywhere.)
public struct Rect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: Vec2 { Vec2(x + width / 2, y + height / 2) }
    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }
}

/// Pixel dimensions of an image.
public struct PixelSize: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var longEdge: Int { max(width, height) }
}

/// How a model expresses coordinates in its answer.
public enum ModelCoordinateSpace: String, Codable, Sendable, CaseIterable {
    /// Pixels of the image exactly as it was sent (the prompt states the size).
    case imagePixels
    /// 0...1000 on both axes regardless of image size (common for Qwen/Gemma-family grounding).
    case normalized1000
    /// 0...1 fractions.
    case normalizedUnit
}

/// Everything needed to map a point the model returns back onto the real screen. Created at capture time
/// and never uploaded in full (only the image size and cursor position are told to the model).
public struct CaptureRecord: Equatable, Sendable, Codable {
    /// `CGDirectDisplayID` of the captured display.
    public var displayID: UInt32
    /// The display's frame in AppKit global points.
    public var displayFrame: Rect
    /// Backing scale (pixels per point) of that display, e.g. 2.0 on Retina.
    public var pointPixelScale: Double
    /// Size of the raw capture in pixels.
    public var capturePixels: PixelSize
    /// Size of the image actually sent to the model (after pre-sizing).
    public var sentPixels: PixelSize
    /// The system pointer at key-down, in global points.
    public var cursorGlobal: Vec2
    /// Bundle identifier of the frontmost app at key-down (for prompt facts and policy).
    public var frontmostBundleID: String?
    /// `ProcessInfo.systemUptime` when the capture started.
    public var capturedAtUptime: TimeInterval

    public init(displayID: UInt32, displayFrame: Rect, pointPixelScale: Double, capturePixels: PixelSize,
                sentPixels: PixelSize, cursorGlobal: Vec2, frontmostBundleID: String?, capturedAtUptime: TimeInterval) {
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.pointPixelScale = pointPixelScale
        self.capturePixels = capturePixels
        self.sentPixels = sentPixels
        self.cursorGlobal = cursorGlobal
        self.frontmostBundleID = frontmostBundleID
        self.capturedAtUptime = capturedAtUptime
    }

    /// Ratio of sent pixels to display points (e.g. 1456 / 1710 ≈ 0.85).
    public var resizeFactor: Double { Double(sentPixels.width) / displayFrame.width }

    /// The pointer in sent-image pixel coordinates (origin top-left), or nil if it was on another display.
    public var cursorInImage: Vec2? {
        guard displayFrame.contains(cursorGlobal) else { return nil }
        return imagePoint(fromGlobal: cursorGlobal)
    }

    /// Global point → sent-image pixel (top-left origin). Uses fractions of the display frame, so the
    /// backing scale never enters the math (no double-scaling bugs on Retina).
    public func imagePoint(fromGlobal p: Vec2) -> Vec2 {
        let u = (p.x - displayFrame.minX) / displayFrame.width
        let v = (displayFrame.maxY - p.y) / displayFrame.height
        return Vec2(u * Double(sentPixels.width), v * Double(sentPixels.height))
    }

    /// Model coordinate → global AppKit point on the captured display. Values are clamped to the image, so
    /// a slightly out-of-range answer still lands on the right display. Returns nil for non-finite input.
    public func globalPoint(fromModel x: Double, _ y: Double, space: ModelCoordinateSpace = .imagePixels) -> Vec2? {
        guard x.isFinite, y.isFinite else { return nil }
        let (u, v): (Double, Double)
        switch space {
        case .imagePixels:
            u = x / Double(sentPixels.width)
            v = y / Double(sentPixels.height)
        case .normalized1000:
            u = x / 1000
            v = y / 1000
        case .normalizedUnit:
            u = x
            v = y
        }
        let cu = min(max(u, 0), 1)
        let cv = min(max(v, 0), 1)
        // Keep the result strictly inside the display so it never lands on a neighbour.
        let gx = displayFrame.minX + cu * displayFrame.width
        let gy = displayFrame.maxY - cv * displayFrame.height
        return Vec2(min(max(gx, displayFrame.minX), displayFrame.maxX - 0.5),
                    min(max(gy, displayFrame.minY + 0.5), displayFrame.maxY - 0.5))
    }

    /// Model-space rectangle (x, y = top-left, width, height) → global AppKit rect.
    public func globalRect(fromModel x: Double, _ y: Double, width: Double, height: Double,
                           space: ModelCoordinateSpace = .imagePixels) -> Rect? {
        guard let a = globalPoint(fromModel: x, y, space: space),
              let b = globalPoint(fromModel: x + width, y + height, space: space) else { return nil }
        return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// True when a raw model value is plausible for `space` (used to detect a model using another scale).
    public func isInRange(_ x: Double, _ y: Double, space: ModelCoordinateSpace) -> Bool {
        switch space {
        case .imagePixels: return x >= -2 && y >= -2 && x <= Double(sentPixels.width) + 2 && y <= Double(sentPixels.height) + 2
        case .normalized1000: return x >= 0 && y >= 0 && x <= 1000 && y <= 1000
        case .normalizedUnit: return x >= 0 && y >= 0 && x <= 1 && y <= 1
        }
    }
}

/// Image pre-sizing.
public enum ImageSizing {
    /// Largest aspect-preserving size whose long edge is at most `longEdge` (never upscales).
    /// Dimensions are rounded to even numbers for encoder friendliness.
    public static func fit(_ size: PixelSize, longEdge: Int) -> PixelSize {
        guard size.longEdge > longEdge, size.width > 0, size.height > 0 else { return size }
        let k = Double(longEdge) / Double(size.longEdge)
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return PixelSize(width: even(Double(size.width) * k), height: even(Double(size.height) * k))
    }
}
