import XCTest
import SentryKit

/// `HistoryRange.since(now:)` is pure and pinnable via its `now` parameter,
/// matching `TimeRangePickerTests`'s own reasoning for asserting exact dates
/// rather than just "it doesn't crash."
final class HistoryRangeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testLast24HoursSinceIsOneDayBack() {
        XCTAssertEqual(HistoryRange.last24Hours.since(now: now), now.addingTimeInterval(-86400))
    }

    func testLast7DaysSinceIsSevenDaysBack() {
        XCTAssertEqual(HistoryRange.last7Days.since(now: now), now.addingTimeInterval(-7 * 86400))
    }

    func testLast30DaysSinceIsThirtyDaysBack() {
        XCTAssertEqual(HistoryRange.last30Days.since(now: now), now.addingTimeInterval(-30 * 86400))
    }

    func testLast90DaysSinceIsNinetyDaysBack() {
        XCTAssertEqual(HistoryRange.last90Days.since(now: now), now.addingTimeInterval(-90 * 86400))
    }

    func testAllSinceIsDistantPast() {
        XCTAssertEqual(HistoryRange.all.since(now: now), .distantPast)
    }

    func testSyntheticDayCountsAreOrderedAndPositive() {
        // Not a strict requirement of the type, but the whole point of
        // these counts is "more history for a wider range" — a regression
        // that made, say, .last90Days shorter than .last30Days would defeat
        // the range selector's purpose without any other test catching it.
        let ranges: [HistoryRange] = [.last24Hours, .last7Days, .last30Days, .last90Days, .all]
        let counts = ranges.map(\.syntheticDayCount)
        XCTAssertEqual(counts, counts.sorted())
        for count in counts {
            XCTAssertGreaterThan(count, 0)
        }
    }

    func testEveryCaseHasNonEmptyLabelsAndAccessibilityLabels() {
        for range in HistoryRange.allCases {
            XCTAssertFalse(range.label.isEmpty)
            XCTAssertFalse(range.accessibilityLabel.isEmpty)
        }
    }
}
