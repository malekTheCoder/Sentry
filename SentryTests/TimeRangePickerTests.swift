import XCTest
@testable import Sentry
import SentryKit

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

    // MARK: - autoRefreshInterval (DashboardViewModel.startAutoRefresh's cadence)

    /// `.day` reads `.raw` rows, which land as often as every few seconds —
    /// the fastest-moving tier, so it gets the shortest auto-refresh
    /// interval, but still nowhere near per-tick (see the property's doc
    /// comment for why 3s-cadence polling would be its own always-on-cost
    /// bug).
    func testDayRefreshesEveryThirtySeconds() {
        XCTAssertEqual(TimeRangePicker.day.autoRefreshInterval, 30)
    }

    /// `.week`/`.month`/`.quarter` all read `.hourly` rollups (see
    /// `queryWindow`), so they share one cadence — there's no reason for
    /// three independent poll loops to query the same tier at three
    /// different rates.
    func testHourlyTierRangesShareATwoMinuteCadence() {
        for range: TimeRangePicker in [.week, .month, .quarter] {
            XCTAssertEqual(range.autoRefreshInterval, 120, "\(range) reads the hourly tier and should share its cadence")
        }
    }

    /// `.halfYear` reads `.daily` rollups, which only gain a new row once a
    /// day — refreshing far more often than that buys nothing.
    func testHalfYearRefreshesEveryFifteenMinutes() {
        XCTAssertEqual(TimeRangePicker.halfYear.autoRefreshInterval, 900)
    }

    /// The core claim this task's fix rests on: cheaper (faster-changing)
    /// ranges refresh more often than expensive (slow-changing) ones, never
    /// the reverse. `.day` (raw) < the hourly-tier trio < `.halfYear`
    /// (daily).
    func testCadenceIncreasesMonotonicallyFromDayToHalfYear() {
        XCTAssertLessThan(TimeRangePicker.day.autoRefreshInterval, TimeRangePicker.week.autoRefreshInterval)
        XCTAssertLessThan(TimeRangePicker.week.autoRefreshInterval, TimeRangePicker.halfYear.autoRefreshInterval)
    }
}
