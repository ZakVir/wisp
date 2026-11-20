import XCTest
import CoreGraphics
import ImageIO
@testable import WispCore
@testable import WispMac

final class CustomSkinTests: XCTestCase {
    func testSkinsAlwaysMakeAValidReadableTheme() {
        let skins = [
            CustomSkin(kind: .solid, colors: [RGB(1, 1, 0.2)]),                       // very light yellow
            CustomSkin(kind: .gradient, colors: [RGB(1, 1, 1), RGB(0, 0, 0)]),         // black and white
            CustomSkin(kind: .photo, colors: (0..<6).map { RGB(Double($0) / 5, 0.2, 0.6) }),
            CustomSkin(kind: .gradient, colors: [RGB(0.9, 0.1, 0.3)]),                 // one stop only
        ]
        for skin in skins {
            let theme = skin.theme
            XCTAssertTrue((2...8).contains(theme.palette.count))
            XCTAssertEqual(theme.palette.map(\.luminance), theme.palette.map(\.luminance).sorted(), "darkest first")
            XCTAssertLessThanOrEqual(theme.accent.luminance, 0.33, "white text must stay readable on the accent")
            XCTAssertEqual(theme.id, ThemeCatalog.customID)
        }
    }

    func testResolvedThemeUsesTheSkinOnlyWhenChosen() {
        var overlay = OverlaySettings()
        overlay.customSkin = CustomSkin(kind: .solid, colors: [RGB(0.1, 0.6, 0.3)])
        XCTAssertEqual(overlay.resolvedTheme.id, ThemeCatalog.defaultID)
        overlay.cursorThemeID = ThemeCatalog.customID
        XCTAssertEqual(overlay.resolvedTheme.id, ThemeCatalog.customID)
        overlay.customSkin = nil
        XCTAssertEqual(overlay.resolvedTheme.id, ThemeCatalog.all[0].id, "a missing skin falls back to a built-in theme")
    }

    func testPhotoColoursFindTheVividRegions() {
        // Mostly grey "sky" with a red and a blue region.
        let ctx = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.6, green: 0.6, blue: 0.62, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 60, y: 60, width: 30, height: 30))
        let colors = PaletteExtractor.colors(in: ctx.makeImage()!, count: 5)
        XCTAssertTrue(colors.contains { $0.r > 0.7 && $0.g < 0.3 }, "red found")
        XCTAssertTrue(colors.contains { $0.b > 0.7 && $0.r < 0.3 }, "blue found")
        XCTAssertEqual(colors.map(\.luminance), colors.map(\.luminance).sorted())
    }

    func testPhotoFileIsReadAndHugeFilesAreRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        let photo = dir.appendingPathComponent("photo.png")
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let colors = try PaletteExtractor.colors(from: photo)
        XCTAssertGreaterThanOrEqual(colors.count, 2)

        let huge = dir.appendingPathComponent("huge.jpg")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(PaletteExtractor.maxFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try PaletteExtractor.colors(from: huge)) { XCTAssertEqual($0 as? PaletteExtractor.Failure, .tooLarge) }

        let text = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PaletteExtractor.colors(from: text)) { XCTAssertEqual($0 as? PaletteExtractor.Failure, .unreadable) }
    }
}
