import XCTest
@testable import MacStat
import MacStatKit

/// `TimeRangePicker.queryWindow(now:)` is pure and pinnable via its `now`
/// parameter, so these assert the exact `(since, tier)` pair for every case
/// rather than just "it doesn't crash" — the whole point of the type is
/// that each range lands clear of `HistoryStore`'s tier boundaries (raw
/// <48h, hourly <90d, daily beyond; see `HistoryStore.tier(for:)`), and a
/// future edit that nudges one of these past a boundary should fail a test,
/// not silently start serving `.day` from `.hourly`.
final class TimeRangePickerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDayUsesRawTier() {
        // 24h is comfortably under HistoryStore's 48h raw-tier cutoff.
        let (since, tier) = TimeRangePicker.day.queryWindow(now: now)
        XCTAssertEqual(tier, .raw)
        XCTAssertEqual(since, now.addingTimeInterval(-86400))
    }

    func testWeekUsesHourlyTier() {
        let (since, tier) = TimeRangePicker.week.queryWindow(now: now)
        XCTAssertEqual(tier, .hourly)
        XCTAssertEqual(since, now.addingTimeInterval(-7 * 86400))
    }

    func testMonthUsesHourlyTier() {
        // 30d is comfortably under HistoryStore's 90d hourly-tier cutoff.
        let (since, tier) = TimeRangePicker.month.queryWindow(now: now)
        XCTAssertEqual(tier, .hourly)
        XCTAssertEqual(since, now.addingTimeInterval(-30 * 86400))
    }

    func testQuarterUsesHourlyTier() {
        // 90d sits right at HistoryStore's hourly-tier boundary, so it
        // should still land on `.hourly`, not step down to `.daily`.
        let (since, tier) = TimeRangePicker.quarter.queryWindow(now: now)
        XCTAssertEqual(tier, .hourly)
        XCTAssertEqual(since, now.addingTimeInterval(-90 * 86400))
    }

    func testHalfYearUsesDailyTierWithABoundedSince() {
        // Unlike the old "All" case, 6mo has a real bound rather than
        // `.distantPast`.
        let (since, tier) = TimeRangePicker.halfYear.queryWindow(now: now)
        XCTAssertEqual(tier, .daily)
        XCTAssertEqual(since, now.addingTimeInterval(-182 * 86400))
    }

    func testEveryCaseHasALabelAndAccessibilityLabel() {
        for range in TimeRangePicker.allCases {
            XCTAssertFalse(range.label.isEmpty)
            XCTAssertFalse(range.accessibilityLabel.isEmpty)
        }
    }
}
