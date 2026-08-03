import XCTest
@testable import SentryKit

/// Coverage for `WidgetTimelineScheduler` (`SentryKit/Sync/WidgetTimelineScheduler.swift`)
/// — the pure "when should the widget's timeline reload next" cadence logic
/// behind `SentryWidget`'s `Provider`. Uses a fixed UTC calendar throughout
/// (matching `Freshness`'s fixed-`now` testability convention) so the suite
/// never depends on the machine's local time zone.
final class WidgetTimelineSchedulerTests: XCTestCase {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: hour, minute: minute))!
    }

    // MARK: - Count / basic shape

    func testReturnsRequestedCount() {
        let calendar = utcCalendar
        let now = date(hour: 12, minute: 0, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 4)
        XCTAssertEqual(dates.count, 4)
    }

    func testZeroCountReturnsEmpty() {
        let calendar = utcCalendar
        let now = date(hour: 12, minute: 0, calendar: calendar)
        XCTAssertEqual(WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 0), [])
    }

    func testFirstEntryIsNowItself() {
        let calendar = utcCalendar
        let now = date(hour: 9, minute: 0, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 3)
        XCTAssertEqual(dates.first, now)
    }

    // MARK: - Waking-hours cadence (7am–11pm local)

    func testStepsFifteenMinutesApartDuringWakingHours() {
        let calendar = utcCalendar
        let now = date(hour: 12, minute: 0, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 3)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), WidgetTimelineScheduler.wakingCadence)
        XCTAssertEqual(dates[2].timeIntervalSince(dates[1]), WidgetTimelineScheduler.wakingCadence)
    }

    func testWakingHourStartBoundaryUsesWakingCadence() {
        let calendar = utcCalendar
        let now = date(hour: WidgetTimelineScheduler.wakingHourStart, minute: 0, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 2)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), WidgetTimelineScheduler.wakingCadence)
    }

    // MARK: - Overnight cadence

    func testStepsOneHourApartOvernight() {
        let calendar = utcCalendar
        let now = date(hour: 2, minute: 0, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 3)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), WidgetTimelineScheduler.overnightCadence)
        XCTAssertEqual(dates[2].timeIntervalSince(dates[1]), WidgetTimelineScheduler.overnightCadence)
    }

    func testWakingHourEndBoundaryUsesOvernightCadence() {
        // wakingHourEnd is exclusive — a step starting exactly at that hour
        // is already "not waking," per `WidgetTimelineScheduler`'s doc
        // comment on how each gap is decided by its start point's hour.
        let calendar = utcCalendar
        let now = date(hour: WidgetTimelineScheduler.wakingHourEnd, minute: 0, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 2)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), WidgetTimelineScheduler.overnightCadence)
    }

    func testTransitionFromOvernightIntoWakingHours() {
        // 10:50pm is still "waking" (< wakingHourEnd), so the first step
        // should be the 15-minute waking cadence even though it crosses into
        // the next day.
        let calendar = utcCalendar
        let now = date(hour: 22, minute: 50, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 2)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), WidgetTimelineScheduler.wakingCadence)
    }

    func testTransitionFromWakingIntoOvernightHours() {
        // 6:50am is still "not waking" (< wakingHourStart), so the step
        // starting there should use the overnight cadence even though it
        // lands after wakingHourStart.
        let calendar = utcCalendar
        let now = date(hour: 6, minute: 50, calendar: calendar)
        let dates = WidgetTimelineScheduler.reloadDates(from: now, calendar: calendar, count: 2)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), WidgetTimelineScheduler.overnightCadence)
    }
}
