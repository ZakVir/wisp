import XCTest
import CoreGraphics
@testable import WispMac

final class BlankCaptureTests: XCTestCase {
    private func image(_ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1440, height: 900))
        draw(ctx)
        return ctx.makeImage()!
    }

    func testUniformBlackIsBlank() {
        XCTAssertTrue(ScreenCapturer.looksBlank(image { _ in }))
    }

    func testDarkTerminalWithTextIsNotBlank() {
        // Thin light-grey "lines of text" on black, like a full-screen dark terminal.
        let shot = image { ctx in
            ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            for row in stride(from: 40, to: 860, by: 28) {
                ctx.fill(CGRect(x: 30, y: row, width: Int.random(in: 200...1200), height: 3))
            }
        }
        XCTAssertFalse(ScreenCapturer.looksBlank(shot))
    }

    func testBlackScreenWithJustACursorIsBlank() {
        let shot = image { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 700, y: 450, width: 12, height: 18))
        }
        XCTAssertTrue(ScreenCapturer.looksBlank(shot))
    }
}
