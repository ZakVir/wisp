import XCTest
@testable import WispCore

final class UsageStatsTests: XCTestCase {
    func testSummary() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func t(_ outcome: String, daysAgo: Double, start: Double? = nil) -> TurnTiming {
            var x = TurnTiming(keyDown: 0)
            x.outcome = outcome
            x.date = now.timeIntervalSince1970 - daysAgo * 86_400
            x.keyUp = 10
            if let start { x.firstAudio = 10 + start }
            return x
        }
        let stats = UsageStats.from([t("ok", daysAgo: 1, start: 1.2), t("ok", daysAgo: 2, start: 1.6), t("ok", daysAgo: 10, start: 1.4),
                                     t("math", daysAgo: 0), t("stt_failed", daysAgo: 0), t("vision_timeout", daysAgo: 0)], now: now)
        XCTAssertEqual(stats.answered, 4)
        XCTAssertEqual(stats.answeredThisWeek, 3)
        XCTAssertEqual(stats.answeredLocally, 1)
        XCTAssertEqual(stats.medianStartMs, 1400)
    }
}
