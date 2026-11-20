import XCTest
@testable import WispCore

final class AppActionTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(AppAction.parse("open Notes"), AppAction(app: "Notes", task: nil))
        XCTAssertEqual(AppAction.parse("can you open Autodesk Fusion and start a new project"), AppAction(app: "Autodesk Fusion", task: "start a new project"))
        XCTAssertEqual(AppAction.parse("open a new tab"), AppAction(app: nil, task: "open a new tab"))
        XCTAssertEqual(AppAction.parse("open a new tab in chrome"), AppAction(app: "chrome", task: "open a new tab"))
        XCTAssertEqual(AppAction.parse("switch to Mail"), AppAction(app: "Mail", task: nil))
        XCTAssertNil(AppAction.parse("open the file menu"))
        XCTAssertNil(AppAction.parse("how do I open Notes"))
        XCTAssertNil(AppAction.parse("open this"))
    }

    func testTooBig() {
        XCTAssertTrue(AppAction.isTooBig("start a new project and make a 3D model of a chair"))
        XCTAssertTrue(AppAction.isTooBig("send an email to my boss"))
        XCTAssertFalse(AppAction.isTooBig("start a new project"))
        XCTAssertFalse(AppAction.isTooBig("open a new tab"))
    }
}
