import XCTest
@testable import WispCore

final class DrawingTests: XCTestCase {
    func testRequests() {
        XCTAssertEqual(Drawing.shape(in: "draw a star"), .star)
        XCTAssertEqual(Drawing.shape(in: "Can you draw a big smiley face on the screen?"), .smiley)
        XCTAssertEqual(Drawing.shape(in: "draw me a heart please"), .heart)
        XCTAssertEqual(Drawing.shape(in: "sketch a house"), .house)
        XCTAssertNil(Drawing.shape(in: "draw a cat"), "not a built-in shape: the AI draws it")
        XCTAssertTrue(Drawing.isDrawRequest("draw a cat"))
        XCTAssertNil(Drawing.shape(in: "how do I draw a circle in Keynote"))
        XCTAssertFalse(Drawing.isDrawRequest("how do I draw in Preview"))
    }

    func testSketches() {
        XCTAssertTrue(Drawing.isFreeSketch("draw a cat"))
        XCTAssertTrue(Drawing.isFreeSketch("can you draw me a house with a tree on the screen"))
        XCTAssertFalse(Drawing.isFreeSketch("draw a box around the volume list"))
        XCTAssertFalse(Drawing.isFreeSketch("draw a star"), "built-in shape")
        XCTAssertEqual(Drawing.subject(of: "Can you draw me a cat on the screen?"), "a cat")
        XCTAssertEqual(Drawing.parseStroke("30,50 25,40 20,30")?.count, 3)
        XCTAssertNil(Drawing.parseStroke("Here is a cat:"))
        XCTAssertEqual(Drawing.parseStroke("1. 10,10 20,20")?.count, 2)
    }

    func testStrokesStayInTheBox() {
        for shape in Drawing.Shape.allCases {
            let strokes = Drawing.strokes(shape)
            XCTAssertFalse(strokes.isEmpty, shape.rawValue)
            for stroke in strokes {
                XCTAssertGreaterThanOrEqual(stroke.count, 2)
                for p in stroke { XCTAssertLessThanOrEqual(max(abs(p.x), abs(p.y)), 1.05, shape.rawValue) }
            }
        }
    }
}
