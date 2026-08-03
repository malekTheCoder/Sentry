import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the pure logic behind `MenuBarPane`'s visibility-rule picker
/// (Sentry/Settings/Panes/MenuBarPane.swift).
///
/// The picker cannot select over `VisibilityRule` directly — one case carries
/// an associated value — so it selects over `VisibilityRuleKind` and rebuilds
/// the rule on every change. That mapping is the only place a user's setting
/// can be silently rewritten into a different rule, and no compiler check
/// catches a mis-wired case, so it is pinned here. The rest (`VisibilityThreshold`)
/// exists to stop the UI offering a range that means nothing for the metric's
/// unit, which is likewise invisible until a user meets it.
@MainActor
final class MenuBarVisibilityRuleTests: XCTestCase {

    /// Every rule the model can hold, including a threshold, so a new case
    /// added to `VisibilityRule` shows up here as a compile error in
    /// `VisibilityRuleKind.init(rule:)` rather than as a silent gap.
    private let allRules: [VisibilityRule] = [
        .always,
        .whenAboveThreshold(42),
        .whenOnBattery,
        .whenCharging,
        .whenAssertionActive
    ]

    // MARK: - Round trip

    func testEveryRuleRoundTripsThroughItsKind() {
        for rule in allRules {
            let kind = VisibilityRuleKind(rule: rule)
            let threshold: Double
            if case .whenAboveThreshold(let value) = rule { threshold = value } else { threshold = 0 }
            XCTAssertEqual(kind.rule(threshold: threshold), rule, "\(rule) did not survive the round trip")
        }
    }

    func testDistinctRulesMapToDistinctKinds() {
        // A duplicated case in the `init(rule:)` switch would collapse two
        // rules onto one picker row and quietly rewrite one of them.
        let kinds = allRules.map { VisibilityRuleKind(rule: $0) }
        XCTAssertEqual(Set(kinds).count, allRules.count)
        XCTAssertEqual(Set(kinds), Set(VisibilityRuleKind.allCases))
    }

    func testThresholdSurvivesADetourThroughTheOtherCases() {
        // This is the behavior `parkedThresholds` exists for: the number is
        // handed back to `rule(threshold:)` unchanged no matter which cases the
        // user visited in between.
        let tuned: Double = 73.5
        for kind in VisibilityRuleKind.allCases where kind != .whenAboveThreshold {
            _ = kind.rule(threshold: tuned)
        }
        XCTAssertEqual(
            VisibilityRuleKind.whenAboveThreshold.rule(threshold: tuned),
            .whenAboveThreshold(tuned)
        )
    }

    func testThresholdIsIgnoredButHarmlessForTheValuelessCases() {
        for kind in VisibilityRuleKind.allCases where kind != .whenAboveThreshold {
            XCTAssertEqual(kind.rule(threshold: 1), kind.rule(threshold: 999))
        }
    }

    // MARK: - Labels

    func testEveryKindHasADistinctHumanReadableLabel() {
        let names = VisibilityRuleKind.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains { $0.isEmpty })
        // The assertion case is the plan §10.5 feature; it must not leak the
        // IOPMAssertion vocabulary into the picker.
        XCTAssertEqual(VisibilityRuleKind.whenAssertionActive.displayName, "While keeping the Mac awake")
    }

    // MARK: - Per-unit threshold shaping

    func testDefaultThresholdIsFiniteForEveryUnit() {
        for unit in Self.allUnits {
            let value = VisibilityThreshold.defaultValue(for: unit)
            XCTAssertTrue(value.isFinite, "\(unit) produced a non-finite default")
        }
    }

    func testDefaultThresholdSitsInsideItsOwnSliderRange() {
        // Otherwise selecting the case snaps the slider — and the stored rule —
        // to a value the user never chose.
        for unit in Self.allUnits {
            guard let bounds = VisibilityThreshold.sliderBounds(for: unit) else { continue }
            let value = VisibilityThreshold.defaultValue(for: unit)
            XCTAssertTrue(
                bounds.range.contains(value),
                "\(unit) default \(value) is outside \(bounds.range)"
            )
        }
    }

    func testUnboundedUnitsGetNoSlider() {
        // The specific failure this guards: a 0–100 slider offered for a
        // bytes-per-second metric, where 100 is line noise.
        for unit in [MetricUnit.bytesPerSecond, .bytes, .megahertz, .count, .operationsPerSecond] {
            XCTAssertNil(VisibilityThreshold.sliderBounds(for: unit), "\(unit) should use free entry")
        }
    }

    func testPercentGetsTheFullPercentDomain() {
        let bounds = VisibilityThreshold.sliderBounds(for: .percent)
        XCTAssertEqual(bounds?.range.lowerBound, 0)
        XCTAssertEqual(bounds?.range.upperBound, 100)
    }

    func testSliderRangesAreNonEmptyAndSteppable() {
        for unit in Self.allUnits {
            guard let bounds = VisibilityThreshold.sliderBounds(for: unit) else { continue }
            XCTAssertLessThan(bounds.range.lowerBound, bounds.range.upperBound, "\(unit)")
            XCTAssertGreaterThan(bounds.step, 0, "\(unit)")
        }
    }

    func testEveryUnitHasASpelledOutDescription() {
        for unit in Self.allUnits {
            XCTAssertFalse(
                VisibilityThreshold.unitDescription(for: unit).isEmpty,
                "\(unit) has no spoken unit name"
            )
        }
    }

    // MARK: - Preview summaries

    func testAlwaysHasNoPreviewAnnotation() {
        // `.always` is the absence of a condition; annotating it would make an
        // unconditional module read as conditional in the preview strip.
        XCTAssertNil(VisibilityRule.always.previewSummary(unit: .percent))
    }

    func testEveryConditionalRuleExplainsItselfInThePreview() {
        for rule in allRules where rule != .always {
            XCTAssertNotNil(rule.previewSummary(unit: .percent), "\(rule) has no preview note")
        }
    }

    func testThresholdPreviewUsesTheMetricsOwnFormatter() {
        // The preview strip's whole job is to look like the bar, so the number
        // has to be formatted the way the bar formats it, not printed raw.
        let summary = VisibilityRule.whenAboveThreshold(80).previewSummary(unit: .percent)
        XCTAssertEqual(summary, "Only shown when above 80%")
    }

    // MARK: - Fixtures

    /// `MetricUnit` isn't `CaseIterable` (it's a public model type with no need
    /// to be), so the list is spelled out; a new unit that isn't added here
    /// still fails the switches above at compile time.
    private static let allUnits: [MetricUnit] = [
        .percent, .watts, .celsius, .megahertz, .bytes, .bytesPerSecond,
        .operationsPerSecond, .minutes, .seconds, .millivolts, .milliamps,
        .decibelMilliwatts, .megabitsPerSecond, .boolean, .count, .decimal,
        .thermalLevel
    ]
}
