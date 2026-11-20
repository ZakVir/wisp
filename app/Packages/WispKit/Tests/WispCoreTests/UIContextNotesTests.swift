import XCTest
@testable import WispCore

final class UIContextNotesTests: XCTestCase {
    func testAWindowWithOnlyMenuTitlesIsUnreadable() {
        let menuOnly = UIContext(appName: "Claude", elements: [UIContext.Element(kind: "menu", label: "File", frame: Rect(x: 0, y: 0, width: 40, height: 24))], menus: [])
        XCTAssertTrue(menuOnly.windowUnreadable)
        let withButton = UIContext(appName: "Claude", elements: [UIContext.Element(kind: "button", label: "New", frame: Rect(x: 0, y: 0, width: 40, height: 24))], menus: [])
        XCTAssertFalse(withButton.windowUnreadable)
    }

    func testNotesTellTheModelToUseTheScreenshot() {
        let menus = [UIContext.MenuItem(menu: "File", title: "New Session")]
        let text = UIContextFormat.text(appName: "Claude", controls: [], menus: menus, space: .imagePixels,
                                        fullScreen: true, windowUnreadable: true)
        XCTAssertTrue(text.contains("macOS can't see the controls inside Claude's window"))
        XCTAssertTrue(text.contains("Claude is full screen, so its menu bar is hidden"))
        XCTAssertTrue(text.contains("- File: New Session"))
        let plain = UIContextFormat.text(appName: "Preview", controls: [], menus: menus, space: .imagePixels)
        XCTAssertFalse(plain.contains("full screen"))
        XCTAssertFalse(plain.contains("can't see"))
    }
}
