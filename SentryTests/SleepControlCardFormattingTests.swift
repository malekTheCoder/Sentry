import XCTest
@testable import Sentry
@testable import SentryKit

/// Covers the pure logic behind the dropdown's sleep-prevention card
/// (Sentry/Dropdown/SleepControlCard.swift): countdown/preset text and the
/// `SleepTriggerOption` → `PowerControlService` argument mapping. The SwiftUI
/// body itself isn't tested here — this is the part that can be wrong without
/// looking wrong.
final class SleepControlCardFormattingTests: XCTestCase {

    // MARK: countdown

    func testCountdownShowsMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(249), "4:09")
        XCTAssertEqual(SleepCountdownFormatting.countdown(9), "0:09")
        XCTAssertEqual(SleepCountdownFormatting.countdown(59 * 60), "59:00")
    }

    func testCountdownShowsHoursWhenPresent() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(3849), "1:04:09")
        XCTAssertEqual(SleepCountdownFormatting.countdown(8 * 3600), "8:00:00")
    }

    /// A fresh 15-minute assertion must read 15:00 on the first tick, not
    /// 14:59 — the deadline is a hair under 900s by the time the view formats it.
    func testCountdownRoundsUpSoAFreshPresetShowsItsFullDuration() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(899.998), "15:00")
    }

    /// The releasing `Timer` can land a moment late; the card must never
    /// flash a negative clock on the way out.
    func testCountdownClampsAtZero() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(0), "0:00")
        XCTAssertEqual(SleepCountdownFormatting.countdown(-30), "0:00")
    }

    func testCountdownRejectsNonFiniteValues() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(.infinity), MetricFormatting.placeholder)
        XCTAssertEqual(SleepCountdownFormatting.countdown(.nan), MetricFormatting.placeholder)
    }

    // MARK: presetLabel

    func testPresetLabelsMatchThePlansDurationMenu() {
        let labels = SleepTriggerOption.allOptions.compactMap { $0.duration }.map(SleepCountdownFormatting.presetLabel)
        XCTAssertEqual(labels, ["15 min", "30 min", "1 h", "2 h", "4 h", "8 h"])
    }

    func testPresetLabelCombinesHoursAndMinutes() {
        XCTAssertEqual(SleepCountdownFormatting.presetLabel(90 * 60), "1 h 30 min")
    }

    // MARK: trigger mapping

    /// Shared no-op arguments for the two new conditional triggers, so the
    /// pre-existing tests below (battery/CPU/process/fixed/indefinite) don't
    /// need to care about download timeouts or schedules they aren't
    /// exercising.
    private let noDownloadTimeout: TimeInterval = 8
    private let noSchedule = KeepAwakeSchedule.weeknights
    private let noUntilTime = Date(timeIntervalSince1970: 1_700_000_000)

    func testFixedTriggersCarryADurationAndNoCondition() {
        let option = SleepTriggerOption.fixed(30 * 60)
        XCTAssertEqual(option.duration, 1800)
        XCTAssertNil(option.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule))
    }

    func testIndefiniteTriggerCarriesNeitherDurationNorCondition() {
        XCTAssertNil(SleepTriggerOption.indefinite.duration)
        XCTAssertNil(SleepTriggerOption.indefinite.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule))
    }

    /// Conditional triggers must stay open-ended: handing a duration to
    /// `startConditionalAssertion` would arm an expiry timer that releases the
    /// assertion before its condition ever fires.
    func testConditionalTriggersHaveNoDurationAndMapToReleaseConditions() {
        XCTAssertNil(SleepTriggerOption.batteryBelow.duration)
        XCTAssertNil(SleepTriggerOption.cpuAbove.duration)
        XCTAssertEqual(
            SleepTriggerOption.batteryBelow.releaseCondition(batteryThreshold: 15, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule),
            .batteryBelowPercent(15)
        )
        XCTAssertEqual(
            SleepTriggerOption.cpuAbove.releaseCondition(batteryThreshold: 20, cpuThreshold: 70, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule),
            .cpuAbovePercent(70, for: 300)
        )
    }

    func testProcessTriggerMapsToWhileProcessRunning() {
        XCTAssertNil(SleepTriggerOption.processRunning.duration)
        XCTAssertEqual(
            SleepTriggerOption.processRunning.releaseCondition(
                batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "xcodebuild",
                downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule
            ),
            .whileProcessRunning(name: "xcodebuild")
        )
        XCTAssertTrue(
            SleepTriggerOption.processRunning
                .assertionReason(batteryThreshold: 20, cpuThreshold: 80, processName: "xcodebuild", schedule: noSchedule, untilTime: noUntilTime)
                .contains("xcodebuild"),
            "process reason should name the watched process"
        )
    }

    func testDownloadActiveTriggerMapsToWhileDownloadActive() {
        XCTAssertNil(SleepTriggerOption.downloadActive.duration)
        XCTAssertEqual(
            SleepTriggerOption.downloadActive.releaseCondition(
                batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude",
                downloadIdleTimeout: 8, schedule: noSchedule
            ),
            .whileDownloadActive(idleTimeout: 8)
        )
    }

    func testScheduledWindowTriggerMapsToScheduledWindowUsingTheChosenPreset() {
        XCTAssertNil(SleepTriggerOption.scheduledWindow.duration)
        XCTAssertEqual(
            SleepTriggerOption.scheduledWindow.releaseCondition(
                batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude",
                downloadIdleTimeout: noDownloadTimeout, schedule: .workHours
            ),
            .scheduledWindow(weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 17 * 60)
        )
    }

    func testMenuOrderMatchesPlanSection103() {
        XCTAssertEqual(
            SleepTriggerOption.allOptions.map(\.id),
            ["indefinite", "fixed-900", "fixed-1800", "fixed-3600", "fixed-7200", "fixed-14400", "fixed-28800", "until-time", "battery", "cpu", "process", "download", "schedule"]
        )
    }

    // MARK: untilTime

    /// `.untilTime` has no fixed `duration` — it needs `now` to turn a clock
    /// time into a countdown, which `resolvedDuration` alone provides.
    func testUntilTimeHasNoFixedDuration() {
        XCTAssertNil(SleepTriggerOption.untilTime.duration)
        XCTAssertNil(SleepTriggerOption.untilTime.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule))
    }

    /// The ordinary case: the picked time is later today.
    func testUntilTimeResolvesToTheRemainderOfToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 14, minute: 0))!
        let untilTime = calendar.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 22, minute: 30))!
        let resolved = try XCTUnwrap(SleepTriggerOption.untilTime.resolvedDuration(untilTime: untilTime, now: now, calendar: calendar))
        XCTAssertEqual(resolved, 8 * 3600 + 30 * 60, accuracy: 0.001)
    }

    /// A time already passed today rolls to tomorrow rather than going
    /// negative — the same "always in the future" guarantee a keep-awake
    /// utility's own "Until" trigger should give.
    func testUntilTimeRollsToTomorrowWhenTheTimeHasAlreadyPassedToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 14, minute: 0))!
        let untilTime = calendar.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 9, minute: 0))!
        let resolved = try XCTUnwrap(SleepTriggerOption.untilTime.resolvedDuration(untilTime: untilTime, now: now, calendar: calendar))
        XCTAssertEqual(resolved, 19 * 3600, accuracy: 0.001)
    }

    /// Inside the 60s floor — treated the same as "already passed," rolling
    /// to tomorrow rather than arming a near-zero assertion.
    func testUntilTimeInsideTheFloorRollsToTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 14, minute: 0, second: 45))!
        let untilTime = calendar.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 14, minute: 1))!
        let resolved = SleepTriggerOption.untilTime.resolvedDuration(untilTime: untilTime, now: now, calendar: calendar)!
        XCTAssertGreaterThan(resolved, 23 * 3600, "a sub-minute gap should roll to tomorrow, not resolve to ~15 seconds")
    }

    func testUntilTimeMenuLabelNamesTheClockTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let untilTime = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 22, minute: 30))!
        let label = SleepTriggerOption.untilTime.menuLabel(batteryThreshold: 20, cpuThreshold: 80, processName: "claude", schedule: noSchedule, untilTime: untilTime)
        XCTAssertTrue(label.contains("Until"), "menu label should read as an 'Until <time>' sentence, got: \(label)")
    }

    /// The reason string is the only description of a conditional trigger that
    /// survives into `SleepAssertionState` (the condition itself is private to
    /// `PowerControlService`), so the active card renders it verbatim — it has
    /// to name the actual threshold.
    func testAssertionReasonNamesTheChosenThreshold() {
        XCTAssertTrue(
            SleepTriggerOption.batteryBelow.assertionReason(batteryThreshold: 25, cpuThreshold: 80, processName: "claude", schedule: noSchedule, untilTime: noUntilTime).contains("25%"),
            "battery reason should name its threshold"
        )
        XCTAssertTrue(
            SleepTriggerOption.cpuAbove.assertionReason(batteryThreshold: 20, cpuThreshold: 65, processName: "claude", schedule: noSchedule, untilTime: noUntilTime).contains("65%"),
            "CPU reason should name its threshold"
        )
    }

    func testDownloadAndScheduleAssertionReasonsAreDescriptive() {
        XCTAssertTrue(
            SleepTriggerOption.downloadActive.assertionReason(batteryThreshold: 20, cpuThreshold: 80, processName: "claude", schedule: noSchedule, untilTime: noUntilTime).contains("download"),
            "download reason should mention what it's watching"
        )
        XCTAssertTrue(
            SleepTriggerOption.scheduledWindow.assertionReason(batteryThreshold: 20, cpuThreshold: 80, processName: "claude", schedule: .workHours, untilTime: noUntilTime).contains(KeepAwakeSchedule.workHours.label),
            "schedule reason should name the chosen preset"
        )
    }

    // MARK: KeepAwakeSchedule presets

    func testEveryKeepAwakeSchedulePresetHasADistinctLabel() {
        let labels = Set(KeepAwakeSchedule.presets.map(\.label))
        XCTAssertEqual(labels.count, KeepAwakeSchedule.presets.count)
    }

    func testWeekendPresetCoversTheFullDayViaEndMinute1440() {
        XCTAssertEqual(KeepAwakeSchedule.weekend.startMinute, 0)
        XCTAssertEqual(KeepAwakeSchedule.weekend.endMinute, 1440)
    }

    // MARK: mode labels

    func testEveryAwakeModeHasDistinctUserFacingText() {
        let shorts = Set(AwakeMode.allCases.map(\.shortLabel))
        let longs = Set(AwakeMode.allCases.map(\.longLabel))
        let explanations = Set(AwakeMode.allCases.map(\.explanation))
        XCTAssertEqual(shorts.count, AwakeMode.allCases.count)
        XCTAssertEqual(longs.count, AwakeMode.allCases.count)
        XCTAssertEqual(explanations.count, AwakeMode.allCases.count)
    }
}
