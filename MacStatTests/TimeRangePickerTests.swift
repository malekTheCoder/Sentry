import XCTest
@testable import MacStat
import MacStatKit

/// `TimeRangePicker.queryWindow(now:)` is pure and pinnable via its `now`
/// parameter, so these assert the exact `(since, tier)` pair for every case
/// rather than just "it doesn't crash" — the whole point of the type is
/// that each range lands clear of `HistoryStore`'s tier boundaries (raw
/// <48h, hourly <90d, daily beyond; see `HistoryStore.tier(for:)`), and a
/// future edit that nudges one of these past a boundary should fail a test,
/// not silently start serving `.oneDay` from `.hourly`.
final class TimeRangePickerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testOneHourUsesRawTier() {
        let (since, tier) = TimeRangePicker.oneHour.queryWindow(now: now)
        XCTAssertEqual(tier, .raw)
        XCTAssertEqual(since, now.addingTimeInterval(-3600))
    }

    func testOneDayUsesRawTier() {
        // 24h is comfortably under HistoryStore's 48h raw-tier cutoff.
        let (since, tier) = TimeRangePicker.oneDay.queryWindow(now: now)
        XCTAssertEqual(tier, .raw)
        XCTAssertEqual(since, now.addingTimeInterval(-86400))
    }

    func testSevenDaysUsesHourlyTier() {
        let (since, tier) = TimeRangePicker.sevenDays.queryWindow(now: now)
        XCTAssertEqual(tier, .hourly)
        XCTAssertEqual(since, now.addingTimeInterval(-7 * 86400))
    }

    func testThirtyDaysUsesHourlyTier() {
        // 30d is comfortably under HistoryStore's 90d hourly-tier cutoff.
        let (since, tier) = TimeRangePicker.thirtyDays.queryWindow(now: now)
        XCTAssertEqual(tier, .hourly)
        XCTAssertEqual(since, now.addingTimeInterval(-30 * 86400))
    }

    func testAllUsesDailyTierSinceDistantPast() {
        let (since, tier) = TimeRangePicker.all.queryWindow(now: now)
        XCTAssertEqual(tier, .daily)
        XCTAssertEqual(since, .distantPast)
    }

    func testEveryCaseHasALabelAndAccessibilityLabel() {
        for range in TimeRangePicker.allCases {
            XCTAssertFalse(range.label.isEmpty)
            XCTAssertFalse(range.accessibilityLabel.isEmpty)
        }
    }
}
