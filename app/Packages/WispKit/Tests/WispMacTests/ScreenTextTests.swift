import XCTest
import AppKit
@testable import WispCore
@testable import WispMac

final class ScreenTextTests: XCTestCase {
    /// A fake toolbar: labels drawn where a real app would put them.
    private func toolbar() -> CGImage {
        let w = 1456, h = 900
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = graphics
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.black]
        // CoreGraphics origin is bottom-left: y = 900 - 80 - 30 puts the text ~80 px from the top.
        ("First Aid" as NSString).draw(at: NSPoint(x: 620, y: h - 110), withAttributes: attrs)
        ("Partition" as NSString).draw(at: NSPoint(x: 800, y: h - 110), withAttributes: attrs)
        ("Erase" as NSString).draw(at: NSPoint(x: 960, y: h - 110), withAttributes: attrs)
        ("Macintosh HD - Data" as NSString).draw(at: NSPoint(x: 60, y: h - 300), withAttributes: attrs)
        NSGraphicsContext.current = nil
        return ctx.makeImage()!
    }

    func testFindsLabelsNearTheirPosition() throws {
        let text = try XCTUnwrap(ScreenText.recognize(toolbar()))
        XCTAssertFalse(text.lines.isEmpty)
        // "First Aid" was drawn at x≈620…740, y≈80…110 (top-left origin).
        let hit = text.box(for: "First Aid", near: Vec2(690, 95), maxDistance: 120)
        XCTAssertNotNil(hit)
        if let hit { XCTAssertLessThan(abs(hit.center.x - 680), 60); XCTAssertLessThan(abs(hit.center.y - 95), 40) }
        XCTAssertNotNil(text.box(for: "Erase button", near: Vec2(1000, 100), maxDistance: 120), "control words are ignored")
        XCTAssertNotNil(text.box(for: "macintosh hd", near: Vec2(120, 290), maxDistance: 120), "case and a partial run of words")
    }

    func testRejectsWhatIsNotThereOrFarAway() throws {
        let text = try XCTUnwrap(ScreenText.recognize(toolbar()))
        XCTAssertNil(text.box(for: "llama", near: Vec2(728, 450), maxDistance: 200))
        XCTAssertNil(text.box(for: "First Aid", near: Vec2(728, 700), maxDistance: 120), "right label, wrong place")
        XCTAssertNil(text.box(for: "e", near: Vec2(690, 95), maxDistance: 120), "a single letter is never a match")
    }
}
