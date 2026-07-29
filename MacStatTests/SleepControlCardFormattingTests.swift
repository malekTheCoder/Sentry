import XCTest
@testable import MacStat
@testable import MacStatKit

/// Covers the pure logic behind the dropdown's sleep-prevention card
/// (MacStat/Dropdown/SleepControlCard.swift): countdown/preset text and the
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

    func testFixedTriggersCarryADurationAndNoCondition() {
        let option = SleepTriggerOption.fixed(30 * 60)
        XCTAssertEqual(option.duration, 1800)
        XCTAssertNil(option.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300))
    }

    func testIndefiniteTriggerCarriesNeitherDurationNorCondition() {
        XCTAssertNil(SleepTriggerOption.indefinite.duration)
        XCTAssertNil(SleepTriggerOption.indefinite.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300))
    }

    /// Conditional triggers must stay open-ended: handing a duration to
    /// `startConditionalAssertion` would arm an expiry timer that releases the
    /// assertion before its condition ever fires.
    func testConditionalTriggersHaveNoDurationAndMapToReleaseConditions() {
        XCTAssertNil(SleepTriggerOption.batteryBelow.duration)
        XCTAssertNil(SleepTriggerOption.cpuAbove.duration)
        XCTAssertEqual(
            SleepTriggerOption.batteryBelow.releaseCondition(batteryThreshold: 15, cpuThreshold: 80, cpuSustainedFor: 300),
            .batteryBelowPercent(15)
        )
        XCTAssertEqual(
            SleepTriggerOption.cpuAbove.releaseCondition(batteryThreshold: 20, cpuThreshold: 70, cpuSustainedFor: 300),
            .cpuAbovePercent(70, for: 300)
        )
    }

    func testMenuOrderMatchesPlanSection103() {
        XCTAssertEqual(
            SleepTriggerOption.allOptions.map(\.id),
            ["indefinite", "fixed-900", "fixed-1800", "fixed-3600", "fixed-7200", "fixed-14400", "fixed-28800", "battery", "cpu"]
        )
    }

    /// The reason string is the only description of a conditional trigger that
    /// survives into `SleepAssertionState` (the condition itself is private to
    /// `PowerControlService`), so the active card renders it verbatim — it has
    /// to name the actual threshold.
    func testAssertionReasonNamesTheChosenThreshold() {
        XCTAssertTrue(
            SleepTriggerOption.batteryBelow.assertionReason(batteryThreshold: 25, cpuThreshold: 80).contains("25%"),
            "battery reason should name its threshold"
        )
        XCTAssertTrue(
            SleepTriggerOption.cpuAbove.assertionReason(batteryThreshold: 20, cpuThreshold: 65).contains("65%"),
            "CPU reason should name its threshold"
        )
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
