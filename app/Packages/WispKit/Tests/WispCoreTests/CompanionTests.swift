import XCTest
@testable import WispCore

final class CompanionThemeTests: XCTestCase {
    func testCatalogHasFourteenUniqueThemesWithValidPalettes() {
        XCTAssertEqual(ThemeCatalog.all.count, 14)
        XCTAssertEqual(Set(ThemeCatalog.all.map(\.id)).count, 14)
        for theme in ThemeCatalog.all {
            XCTAssertTrue((2...8).contains(theme.palette.count))
            // Palettes run dark to bright so the fluid value maps intuitively.
            XCTAssertLessThan(theme.palette.first!.luminance, theme.palette.last!.luminance, theme.id)
        }
        XCTAssertEqual(ThemeCatalog.theme(id: "nope").id, ThemeCatalog.defaultID)
    }

    func testPaletteInterpolation() {
        let t = ThemeCatalog.theme(id: "aurora")
        XCTAssertEqual(t.color(at: 0), t.palette.first)
        XCTAssertEqual(t.color(at: 1), t.palette.last)
        XCTAssertEqual(t.color(at: -3), t.palette.first, "clamped")
    }
}

final class FlightTests: XCTestCase {
    func testEndpointsAndArc() {
        let path = FlightPath(start: Vec2(0, 0), end: Vec2(100, 0), arc: 0.2)
        XCTAssertEqual(path.point(at: 0), Vec2(0, 0))
        XCTAssertEqual(path.point(at: 1).x, 100, accuracy: 1e-9)
        XCTAssertGreaterThan(path.point(at: 0.5).y, 5, "arcs to the left of travel (upwards here)")
        XCTAssertEqual(path.direction(at: 0.5).x, 1, accuracy: 1e-9)
    }

    func testEasingEndpointsAndOvershoot() {
        XCTAssertEqual(Easing.inOutCubic(0), 0)
        XCTAssertEqual(Easing.inOutCubic(1), 1)
        XCTAssertEqual(Easing.outBack(1), 1, accuracy: 1e-12)
        let peak = stride(from: 0.0, through: 1.0, by: 0.01).map { Easing.outBack($0) }.max()!
        XCTAssertGreaterThan(peak, 1.0, "settles with a slight overshoot")
        XCTAssertLessThan(peak, 1.12)
    }

    func testDurationScalesWithDistance() {
        XCTAssertEqual(FlightPath.duration(forDistance: 10), 0.28)
        XCTAssertEqual(FlightPath.duration(forDistance: 10_000), 0.75)
        XCTAssertLessThan(FlightPath.duration(forDistance: 400), FlightPath.duration(forDistance: 1200))
    }
}
