import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for `SentryKit/History/HistoryCoverage.swift` — the arithmetic
/// behind "you asked for 90 days; Sentry has 3."
///
/// Every assertion here is about a claim the app makes to a reader as fact:
/// how much history exists, where the plot's left edge belongs, which stretches
/// of the window are empty, and how the shortfall is worded. The drawing is not
/// tested (a `chartXScale(domain:)` modifier is one line and a test would be
/// asserting that SwiftUI applied it); what *is* tested is every input that
/// line receives.
///
/// Same model as `SentryTests/ChartScrubbingTests.swift`, which covers this
/// file's sibling — see it for why the pure half of a chart feature belongs in
/// `SentryKit` where a test can reach it.
final class HistoryCoverageTests: XCTestCase {

    // MARK: - Helpers

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86400)
    }

    private func window(days: Double) -> ClosedRange<Date> {
        daysAgo(days)...now
    }

    /// The headline scenario: a three-day-old install asking for 90 days.
    private func freshInstall() -> HistoryCoverage {
        HistoryCoverage(
            requested: window(days: 90),
            earliest: daysAgo(3),
            latest: now,
            resolution: 3600
        )
    }

    // MARK: - Spans

    func testRecordedDurationIsTheSpanTheRowsActuallyCover() {
        XCTAssertEqual(freshInstall().recordedDuration, 3 * 86400, accuracy: 0.001)
    }

    func testRecordedDurationIsClippedToTheWindow() {
        // A chart drawing an all-time query into a 7-day window must not count
        // the months of rows that fall outside it.
        let coverage = HistoryCoverage(
            requested: window(days: 7),
            earliest: daysAgo(400),
            latest: now
        )
        XCTAssertEqual(coverage.recordedDuration, 7 * 86400, accuracy: 0.001)
        XCTAssertEqual(coverage.fraction, 1, accuracy: 0.001)
    }

    func testRecordedDurationDoesNotCountASilentTail() {
        // A Mac shut two days ago inside a 30-day window has 28 days of record,
        // not 30 — counting up to "now" would put back into the caption the
        // exact overclaim the pinned domain removes from the plot.
        let coverage = HistoryCoverage(
            requested: window(days: 30),
            earliest: daysAgo(30),
            latest: daysAgo(2)
        )
        XCTAssertEqual(coverage.recordedDuration, 28 * 86400, accuracy: 0.001)
    }

    func testEmptySeriesHasNoRecordedDuration() {
        let coverage = HistoryCoverage(requested: window(days: 90), timestamps: [])
        XCTAssertEqual(coverage.recordedDuration, 0)
        XCTAssertEqual(coverage.fraction, 0)
        XCTAssertNil(coverage.beganRecording)
    }

    func testFractionIsClampedToZeroThroughOne() {
        XCTAssertEqual(freshInstall().fraction, 3.0 / 90.0, accuracy: 0.0001)
        // An unbounded request has no denominator to be a fraction of.
        let unbounded = HistoryCoverage(requested: nil, earliest: daysAgo(41), latest: now)
        XCTAssertEqual(unbounded.fraction, 0)
    }

    // MARK: - Unrecorded edges

    func testFreshInstallLeavesTheLeadingEightySevenDaysUnrecorded() {
        let coverage = freshInstall()
        let lead = coverage.unrecordedLead
        XCTAssertNotNil(lead)
        XCTAssertEqual(lead?.lowerBound, daysAgo(90))
        XCTAssertEqual(lead?.upperBound, daysAgo(3))
        XCTAssertNil(coverage.unrecordedTail)
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(coverage.unrecordedEdges.count, 1)
    }

    func testAFullWindowHasNoUnrecordedEdges() {
        let coverage = HistoryCoverage(
            requested: window(days: 30),
            earliest: daysAgo(30),
            latest: now,
            resolution: 3600
        )
        XCTAssertNil(coverage.unrecordedLead)
        XCTAssertNil(coverage.unrecordedTail)
        XCTAssertTrue(coverage.isComplete)
        XCTAssertTrue(coverage.unrecordedEdges.isEmpty)
    }

    func testARowLandingJustInsideTheWindowIsNotAShortfall() {
        // The normal state of every full chart in the app: the query's `since`
        // is a wall-clock instant and the first row after it lands seconds or
        // minutes later. Flagging that would make the shortfall wash and the
        // "N of M" wording fire permanently, on every chart, forever.
        let coverage = HistoryCoverage(
            requested: window(days: 30),
            earliest: daysAgo(30).addingTimeInterval(120),
            latest: now,
            resolution: 3600
        )
        XCTAssertTrue(coverage.isComplete)
    }

    func testResolutionRaisesTheToleranceForACoarseTier() {
        // The case this floor exists for, and it is a real one: the phone's
        // health chart plots one `DailyHealth` row per day, stamped at
        // midnight, against a 7-day window ending *now*. The newest row is
        // therefore up to 24h behind the window's end by construction — 14% of
        // the window — so without a resolution floor every single 7-day health
        // chart would permanently show a trailing "unrecorded" band describing
        // nothing but the time of day.
        let week = window(days: 7)
        let dailyRows = HistoryCoverage(
            requested: week,
            earliest: daysAgo(7),
            latest: daysAgo(0.9),
            resolution: 86400
        )
        XCTAssertTrue(dailyRows.isComplete, "one row-interval of silence at the tail is the schedule, not a gap")

        // The same silence on a tier that writes hourly *is* news: 21 hours
        // with no row from a series that promises one an hour means something
        // stopped.
        let hourlyRows = HistoryCoverage(
            requested: week,
            earliest: daysAgo(7),
            latest: daysAgo(0.9),
            resolution: 3600
        )
        XCTAssertNotNil(hourlyRows.unrecordedTail)
        XCTAssertFalse(hourlyRows.isComplete)
    }

    func testASilentTailIsReportedSeparatelyFromALateStart() {
        // Both edges at once: installed 60 days into a 90-day window, Mac shut
        // for the last 5. Two distinct empty regions, both shaded, neither
        // conflated with the other.
        let coverage = HistoryCoverage(
            requested: window(days: 90),
            earliest: daysAgo(60),
            latest: daysAgo(5),
            resolution: 3600
        )
        XCTAssertEqual(coverage.unrecordedLead?.upperBound, daysAgo(60))
        XCTAssertEqual(coverage.unrecordedTail?.lowerBound, daysAgo(5))
        XCTAssertEqual(coverage.unrecordedEdges.count, 2)
        XCTAssertFalse(coverage.isComplete)
    }

    func testAnEmptySeriesLeavesTheWholeWindowUnrecorded() {
        // Not `nil`: a chart asked about 90 days that has nothing must still be
        // able to show the 90 days it was asked about.
        let coverage = HistoryCoverage(requested: window(days: 90), timestamps: [])
        XCTAssertEqual(coverage.unrecordedLead, window(days: 90))
        XCTAssertNil(coverage.unrecordedTail)
        XCTAssertFalse(coverage.isComplete)
    }

    func testAnUnboundedRequestHasNoEdgesToFallShortOf() {
        // The all-time battery-health cards: "everything" has no left edge, so
        // the auto-fitted domain is already the truthful one and there is
        // nothing to pin or to wash.
        let coverage = HistoryCoverage(requested: nil, earliest: daysAgo(41), latest: now)
        XCTAssertNil(coverage.requestedDomain)
        XCTAssertTrue(coverage.unrecordedEdges.isEmpty)
        XCTAssertTrue(coverage.isComplete)
    }

    // MARK: - Domain

    func testRequestedDomainIsExactlyTheWindowAsked() {
        XCTAssertEqual(freshInstall().requestedDomain, window(days: 90))
    }

    // MARK: - Combining series

    func testCombiningTakesTheOldestStartAcrossMetrics() {
        // A module enabled yesterday has a much later first row than CPU. The
        // header answers "how far back does this Mac's record go", so the
        // oldest row anything holds is the right answer — reporting the newest
        // would understate the history the user actually has.
        let cpu = HistoryCoverage(requested: window(days: 30), earliest: daysAgo(12), latest: now, resolution: 3600)
        let thermal = HistoryCoverage(requested: window(days: 30), earliest: daysAgo(1), latest: daysAgo(0.5), resolution: 3600)
        let combined = HistoryCoverage.combining([cpu, thermal])
        XCTAssertEqual(combined?.earliest, daysAgo(12))
        XCTAssertEqual(combined?.latest, now)
        XCTAssertEqual(combined?.requested, window(days: 30))
    }

    func testCombiningNothingIsNil() {
        XCTAssertNil(HistoryCoverage.combining([]))
    }

    func testCombiningIgnoresEmptySeries() {
        let empty = HistoryCoverage(requested: window(days: 7), timestamps: [])
        let real = HistoryCoverage(requested: window(days: 7), earliest: daysAgo(2), latest: now)
        let combined = HistoryCoverage.combining([empty, real])
        XCTAssertEqual(combined?.earliest, daysAgo(2))
    }

    // MARK: - Quantities

    func testQuantityFloorsRatherThanRounds() {
        // Floored in one direction on purpose: 3.9 days must read as "3 days".
        // Rounding would let 3.6 days claim four, which is the exact species of
        // small overclaim this file exists to remove.
        XCTAssertEqual(HistoryCoverage.quantity(3.9 * 86400).value, 3)
        XCTAssertEqual(HistoryCoverage.quantity(3.9 * 86400).unit, .days)
    }

    func testQuantitySwitchesUnitAtFortyEightHours() {
        // Same boundary `DashboardChart.xAxisFormat` uses, so the caption's
        // unit and the axis labels' granularity change at the same moment.
        XCTAssertEqual(HistoryCoverage.quantity(47 * 3600).unit, .hours)
        XCTAssertEqual(HistoryCoverage.quantity(48 * 3600).unit, .days)
        XCTAssertEqual(HistoryCoverage.quantity(48 * 3600).value, 2)
    }

    func testQuantityOfNegativeOrZeroDurationIsZeroHours() {
        XCTAssertEqual(HistoryCoverage.quantity(-500).value, 0)
        XCTAssertEqual(HistoryCoverage.quantity(0).unit, .hours)
    }

    func testPhraseIsSingularOrPluralAndNeverZero() {
        XCTAssertEqual(HistoryCoverage.phrase(86400), "24 hours")
        XCTAssertEqual(HistoryCoverage.phrase(3600), "1 hour")
        XCTAssertEqual(HistoryCoverage.phrase(3 * 86400), "3 days")
        XCTAssertEqual(HistoryCoverage.phrase(48 * 3600), "2 days")
        // "0 hours" would read as "none" — the opposite error from an
        // overclaim, but an error all the same on a Mac that has been running
        // for twenty minutes.
        XCTAssertEqual(HistoryCoverage.phrase(1200), "under an hour")
    }

    // MARK: - Labels

    func testCompleteWindowStatesTheWindowsOwnLength() {
        let day = HistoryCoverage(
            requested: window(days: 1),
            earliest: daysAgo(1),
            latest: now,
            resolution: 3
        )
        XCTAssertEqual(day.label, "24 hours recorded")

        let quarter = HistoryCoverage(
            requested: window(days: 90),
            earliest: daysAgo(90),
            latest: now,
            resolution: 3600
        )
        XCTAssertEqual(quarter.label, "90 days recorded")
    }

    func testShortWindowStatesBothNumbers() {
        // The whole feature in one string: the user asked for 90 and has 3, and
        // the sentence says exactly that rather than leaving it to the shape of
        // a line.
        XCTAssertEqual(freshInstall().label, "3 of 90 days recorded")
    }

    func testShortWindowKeepsBothUnitsWhenTheyDiffer() {
        // "5 of 90" that silently meant hours-of-days would be wrong by a
        // factor of 24, so the mixed case spells both units out.
        let coverage = HistoryCoverage(
            requested: window(days: 90),
            earliest: now.addingTimeInterval(-5 * 3600),
            latest: now,
            resolution: 3600
        )
        XCTAssertEqual(coverage.label, "5 hours of 90 days recorded")
    }

    func testEmptyWindowSaysNothingWasRecorded() {
        let coverage = HistoryCoverage(requested: window(days: 7), timestamps: [])
        XCTAssertEqual(coverage.label, "nothing recorded in the last 7 days")
    }

    func testUnboundedRequestStatesHowMuchHistoryExists() {
        // What the all-time battery-health cards need: no window to fall short
        // of, but a three-day-old install still deserves to be told it is
        // three days old.
        let coverage = HistoryCoverage(requested: nil, earliest: daysAgo(41), latest: now)
        XCTAssertEqual(coverage.label, "41 days recorded")
    }

    func testUnboundedRequestWithNoSamplesSaysNothingAtAll() {
        // The chart's own empty state already carries the whole message; a
        // caption repeating it would be the second of two identical sentences.
        XCTAssertNil(HistoryCoverage(requested: nil, timestamps: []).label)
    }

    func testStartDescriptionNamesTheDayTheRecordBegins() {
        let coverage = freshInstall()
        let start = coverage.startDescription()
        XCTAssertNotNil(start)
        XCTAssertTrue(start!.hasPrefix("since "), "unexpected start description: \(start!)")
        XCTAssertNil(HistoryCoverage(requested: window(days: 7), timestamps: []).startDescription())
    }

    func testSummaryAppendsTheStartDateOnlyWhenItAddsSomething() {
        // Short window: the reader wants to know whether "3 of 90 days" lines
        // up with when they installed the app, so the date is worth the room.
        let short = freshInstall().summary
        XCTAssertNotNil(short)
        XCTAssertTrue(short!.hasPrefix("3 of 90 days recorded · since "), "unexpected summary: \(short!)")

        // Complete window: the start date is "90 days ago", which the user just
        // selected in the picker — pure duplication in a caption that has to
        // fit beside a five-segment control.
        let complete = HistoryCoverage(
            requested: window(days: 90),
            earliest: daysAgo(90),
            latest: now,
            resolution: 3600
        )
        XCTAssertEqual(complete.summary, "90 days recorded")

        // Unbounded: "41 days recorded" alone doesn't say *which* 41 days.
        let unbounded = HistoryCoverage(requested: nil, earliest: daysAgo(41), latest: now)
        XCTAssertTrue(unbounded.summary!.hasPrefix("41 days recorded · since "), "unexpected summary: \(unbounded.summary!)")
    }

    // MARK: - The picker's own windows

    func testEveryTimeRangePickerCaseProducesAPinnableDomain() {
        // The regression this guards: a range whose `since` is `.distantPast`
        // (the old "All" case) cannot be a chart domain — `ClosedRange` over a
        // 2,000-year span makes every real sample a sub-pixel sliver at the
        // right edge. Every current case must be a real bounded window.
        for range in TimeRangePicker.allCases {
            let (since, _) = range.queryWindow(now: now)
            XCTAssertGreaterThan(since, now.addingTimeInterval(-200 * 86400), "\(range) must be a bounded window")
            XCTAssertLessThan(since, now)
            let coverage = HistoryCoverage(requested: since...now, earliest: since, latest: now)
            XCTAssertTrue(coverage.isComplete)
            XCTAssertNotNil(coverage.label)
        }
    }

    func testTheAllHistoryRangeIsTheOneCaseWithNoPinnableDomain() {
        // `HistoryRange.all` maps to `.distantPast` deliberately (see its doc
        // comment), which is exactly why the phone's chart must treat it as an
        // unbounded request rather than pinning to a 2,000-year domain.
        XCTAssertEqual(HistoryRange.all.since(now: now), .distantPast)
        for range in HistoryRange.allCases where range != .all {
            XCTAssertGreaterThan(range.since(now: now), now.addingTimeInterval(-200 * 86400))
        }
    }
}
