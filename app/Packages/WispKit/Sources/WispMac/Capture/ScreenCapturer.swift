import AppKit
import CoreImage
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import WispCore

/// One screenshot, ready to send, plus the record that maps model coordinates back to the screen.
public struct CapturedScreen: @unchecked Sendable {
    /// The pre-sized image (sent pixels).
    public let image: CGImage
    public let record: CaptureRecord
    /// Milliseconds spent in ScreenCaptureKit and in resizing, for timing logs.
    public let captureMilliseconds: Double
    public let resizeMilliseconds: Double
    /// True when most of the image is black (protected content, or the display was asleep).
    public let looksBlank: Bool

    /// The same capture with the record's pointer position replaced (used for non-pointer displays).
    func withCursor(_ cursor: Vec2) -> CapturedScreen {
        var record = self.record
        record.cursorGlobal = cursor
        return CapturedScreen(image: image, record: record, captureMilliseconds: captureMilliseconds,
                              resizeMilliseconds: resizeMilliseconds, looksBlank: looksBlank)
    }

    /// JPEG encoding (quality 0.85 keeps small UI text crisp at ~150–300 KB).
    public func jpegData(quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    public func pngData() -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// One-shot capture of the display under the pointer with ScreenCaptureKit. Wisp's own windows (overlay,
/// captions, cards) are excluded through the content filter so the companion never appears in its own
/// screenshot.
public final class ScreenCapturer: @unchecked Sendable {
    public enum CaptureError: Error, Equatable, Sendable {
        case permissionDenied
        case noDisplay
        case failed(String)
    }

    /// Long edge of the image sent to the model.
    public var longEdge: Int = 1456
    /// Include the system pointer in the screenshot (it tells the model what the user is looking at).
    public var showsCursor = true
    /// Ask ScreenCaptureKit to deliver the target size directly instead of capturing full resolution and
    /// downscaling with Lanczos. Faster; benchmark quality before enabling (see FINDINGS.md).
    public var letSystemScale = true
    /// Apps the user made private: their windows are left out of every screenshot (bundle identifiers).
    public var hiddenBundleIDs: Set<String> {
        get { lock.withLock { hidden } }
        set { lock.withLock { hidden = newValue } }
    }
    private var hidden: Set<String> = []

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let lock = NSLock()
    private var cachedContent: SCShareableContent?
    private var cachedAt: TimeInterval = 0

    public init() {}

    /// Fetches the shareable-content list ahead of time (it costs tens of milliseconds).
    public func prewarm() async {
        _ = try? await shareableContent(maxAge: 0)
    }

    /// Captures every display (up to `limit`), the one under the pointer first, so the model can point anywhere.
    public func captureAllDisplays(frontmostBundleID: String? = nil, limit: Int = 3) async throws -> [CapturedScreen] {
        let pointer = NSEvent.mouseLocation
        let frames: [CGRect] = await MainActor.run {
            let screens = NSScreen.screens
            let cursorFirst = screens.sorted { a, _ in NSMouseInRect(pointer, a.frame, false) }
            return cursorFirst.prefix(limit).map(\.frame)
        }
        var shots: [CapturedScreen] = []
        for (i, frame) in frames.enumerated() {
            // Capture each display by a point inside it; the record keeps the real pointer position.
            let inside = i == 0 ? pointer : CGPoint(x: frame.midX, y: frame.midY)
            if i == 0 {
                shots.append(try await captureDisplay(under: inside, frontmostBundleID: frontmostBundleID))
            } else {
                // Another display that fails (just unplugged, asleep) is skipped; the main one is what matters.
                guard let shot = try? await captureDisplay(under: inside, frontmostBundleID: frontmostBundleID) else { continue }
                shots.append(shot.withCursor(Vec2(pointer.x, pointer.y)))
            }
        }
        return shots
    }

    /// A tiny greyscale thumbnail of the display under `point` (AppKit global; Wisp's windows and private apps left
    /// out, no pointer), for telling whether the screen changed during a walkthrough. Stays on this Mac.
    public func fingerprint(under point: CGPoint) async -> ScreenFingerprint? {
        let displayID: CGDirectDisplayID? = await MainActor.run {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
            return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        guard let displayID, let content = try? await shareableContent(maxAge: 5),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hidden = hiddenBundleIDs
        let excluded = content.applications.filter { $0.processID == ownPID || hidden.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = ScreenFingerprint.width * 4
        config.height = ScreenFingerprint.height * 4
        config.showsCursor = false
        config.captureResolution = .nominal
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let w = ScreenFingerprint.width, h = ScreenFingerprint.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? ScreenFingerprint(pixels: pixels) : nil
    }

    /// Captures one window on its own (whatever covers it is left out), at full resolution. For reading a page.
    public func captureWindow(id windowID: CGWindowID) async throws -> CGImage {
        let content: SCShareableContent
        do { content = try await shareableContent(maxAge: 0) } catch { throw CaptureError.permissionDenied }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((Double(filter.contentRect.width) * scale).rounded())
        config.height = Int((Double(filter.contentRect.height) * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = true
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.failed((error as NSError).localizedDescription)
        }
    }

    /// Captures the display containing `point` (global AppKit coordinates; default: the pointer).
    public func captureDisplay(under point: CGPoint? = nil, frontmostBundleID: String? = nil) async throws -> CapturedScreen {
        let start = ProcessInfo.processInfo.systemUptime
        let pointer = point ?? NSEvent.mouseLocation
        let target: (CGDirectDisplayID, CGRect)? = await MainActor.run {
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, screen.frame)
        }
        guard let (displayID, frame) = target else { throw CaptureError.noDisplay }

        let content: SCShareableContent
        do {
            content = try await shareableContent(maxAge: 5)
        } catch {
            throw CGPreflightScreenCaptureAccess() ? CaptureError.failed(error.localizedDescription) : CaptureError.permissionDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            // The display list is stale (display just connected): refresh once.
            let fresh = try await shareableContent(maxAge: 0)
            guard let display = fresh.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
            return try await capture(display: display, content: fresh, frame: frame, pointer: pointer, frontmost: frontmostBundleID, start: start)
        }
        return try await capture(display: display, content: content, frame: frame, pointer: pointer, frontmost: frontmostBundleID, start: start)
    }

    private func capture(display: SCDisplay, content: SCShareableContent, frame: CGRect, pointer: CGPoint,
                         frontmost: String?, start: TimeInterval) async throws -> CapturedScreen {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hidden = hiddenBundleIDs
        var content = content
        // A private app that started after the cached list was made must still be left out: refresh first.
        if !hidden.isEmpty {
            let listed = Set(content.applications.map(\.bundleIdentifier))
            let runningHidden = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { hidden.contains($0) }
            if runningHidden.contains(where: { !listed.contains($0) }) { content = try await shareableContent(maxAge: 0) }
        }
        let excluded = content.applications.filter { $0.processID == ownPID || hidden.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let scale = Double(filter.pointPixelScale)
        let capturePixels = PixelSize(width: Int((Double(filter.contentRect.width) * scale).rounded()),
                                      height: Int((Double(filter.contentRect.height) * scale).rounded()))
        let config = SCStreamConfiguration()
        let systemTarget = ImageSizing.fit(capturePixels, longEdge: longEdge)
        config.width = letSystemScale ? systemTarget.width : capturePixels.width
        config.height = letSystemScale ? systemTarget.height : capturePixels.height
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsDisplay = false

        let raw: CGImage
        do {
            raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.failed((error as NSError).localizedDescription)
        }
        let captured = ProcessInfo.processInfo.systemUptime

        let target = ImageSizing.fit(PixelSize(width: raw.width, height: raw.height), longEdge: longEdge)
        let sized = resize(raw, to: target) ?? raw
        let done = ProcessInfo.processInfo.systemUptime

        let record = CaptureRecord(
            displayID: display.displayID,
            displayFrame: Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            pointPixelScale: scale,
            capturePixels: capturePixels,
            sentPixels: PixelSize(width: sized.width, height: sized.height),
            cursorGlobal: Vec2(pointer.x, pointer.y),
            frontmostBundleID: frontmost,
            capturedAtUptime: start)
        return CapturedScreen(image: sized, record: record,
                              captureMilliseconds: (captured - start) * 1000,
                              resizeMilliseconds: (done - captured) * 1000,
                              looksBlank: Self.looksBlank(sized))
    }

    /// High-quality downscale (Lanczos) so small UI text stays legible to the model.
    private func resize(_ image: CGImage, to size: PixelSize) -> CGImage? {
        guard size.width != image.width || size.height != image.height else { return image }
        let input = CIImage(cgImage: image)
        let scale = Double(size.height) / Double(image.height)
        let aspect = (Double(size.width) / Double(image.width)) / scale
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        return ciContext.createCGImage(output, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func shareableContent(maxAge: TimeInterval) async throws -> SCShareableContent {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedValue(maxAge: maxAge, now: now) { return cached }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        store(content, at: now)
        return content
    }

    private func store(_ content: SCShareableContent, at time: TimeInterval) {
        lock.withLock {
            cachedContent = content
            cachedAt = time
        }
    }

    private func cachedValue(maxAge: TimeInterval, now: TimeInterval) -> SCShareableContent? {
        lock.withLock {
            guard maxAge > 0, let cachedContent, now - cachedAt < maxAge else { return nil }
            return cachedContent
        }
    }

    /// Samples a grid; "blank" only when the whole image is uniformly black (DRM video, locked or sleeping
    /// screen). A dark-mode window with text has bright samples somewhere, so it isn't blank.
    static func looksBlank(_ image: CGImage) -> Bool {
        let w = 96, h = 60
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lit = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) >= 24 {
            lit += 1
        }
        // A cursor or a stray indicator may light a few samples (under 0.2%); anything more is real content.
        return lit * 500 <= w * h
    }
}
