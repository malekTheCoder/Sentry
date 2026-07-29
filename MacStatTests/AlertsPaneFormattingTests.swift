import XCTest
@testable import MacStat
@testable import MacStatKit

/// Coverage for the pure display logic in `AlertsPane`
/// (MacStat/Settings/Panes/AlertsPane.swift). None of this draws anything —
/// it's the arithmetic and the routing that decide whether the pane tells the
/// user the truth, which is exactly the part worth pinning down without a
/// view hierarchy.
@MainActor
final class AlertsPaneFormattingTests: XCTestCase {

    // MARK: - Rule kind routing

    func testSpecialCasedRuleIDsRouteToTheirOwnKinds() {
        XCTAssertEqual(RuleKind(id: AlertEngine.chargingPausedRuleID), .chargingPaused)
        XCTAssertEqual(RuleKind(id: AlertEngine.slowChargingRuleID), .slowCharging)
        XCTAssertEqual(RuleKind(id: AlertEngine.batteryHealthDropRuleID), .batteryHealthDrop)
        XCTAssertEqual(RuleKind(id: UUID()), .generic)
    }

    func testEverySpecialCasedRuleExplainsWhichFieldsDoNotApply() {
        // The editor hides metric/comparison/threshold for these; if the
        // explanation went missing the user would just see fields vanish.
        for kind in [RuleKind.chargingPaused, .slowCharging, .batteryHealthDrop] {
            XCTAssertNotNil(kind.notApplicableNote, "\(kind) must explain itself")
        }
        XCTAssertNil(RuleKind.generic.notApplicableNote)
    }

    func testOnlyTheTwoFullyPlaceholderRulesGetAFixedConditionSummary() {
        // Battery health drop is excluded on purpose: its `threshold` *is*
        // read by the engine, so it gets a real editable field rather than a
        // canned sentence.
        XCTAssertNotNil(RuleKind.chargingPaused.fixedConditionSummary)
        XCTAssertNotNil(RuleKind.slowCharging.fixedConditionSummary)
        XCTAssertNil(RuleKind.batteryHealthDrop.fixedConditionSummary)
        XCTAssertNil(RuleKind.generic.fixedConditionSummary)
    }

    // MARK: - History value rendering

    func testChargingPausedFiringRendersAsAReasonCodeNotAPercentage() {
        // The rule's stored metric is a placeholder the engine never reads,
        // so its logged value is a NotChargingReason code. Formatting it
        // with the placeholder's unit would print a confident, wrong "1%".
        let entry = AlertLogEntry(
            timestamp: Date(),
            ruleID: AlertEngine.chargingPausedRuleID,
            ruleName: "Charging paused",
            metric: MetricID.batteryChargePercent.rawValue,
            value: 1,
            delivered: true,
            suppressed: false
        )
        XCTAssertEqual(AlertsPane.historyValueText(entry), "reason code 1")
    }

    func testKnownMetricFiringRendersInItsOwnUnit() {
        let entry = AlertLogEntry(
            timestamp: Date(),
            ruleID: UUID(),
            ruleName: "Sustained high CPU",
            metric: MetricID.cpuTotalPercent.rawValue,
            value: 93,
            delivered: true,
            suppressed: false
        )
        XCTAssertEqual(
            AlertsPane.historyValueText(entry),
            MetricFormatter.detailed(93, unit: .percent)
        )
    }

    func testUnrecognizedMetricStillRendersARowRatherThanBeingDropped() {
        // A settings file from a build that knows a metric this one doesn't.
        let entry = AlertLogEntry(
            timestamp: Date(),
            ruleID: UUID(),
            ruleName: "Future rule",
            metric: "some.future.metric",
            value: 12.5,
            delivered: false,
            suppressed: true
        )
        XCTAssertEqual(AlertsPane.historyValueText(entry), "12.5")
    }

    // MARK: - Durations

    func testHumanDurationSpellsOutTheShippedRuleValues() {
        XCTAssertEqual(AlertsPane.humanDuration(0), "Fires immediately")
        XCTAssertEqual(AlertsPane.humanDuration(1), "1 second")
        XCTAssertEqual(AlertsPane.humanDuration(30), "30 seconds")
        XCTAssertEqual(AlertsPane.humanDuration(60), "1 minute")
        XCTAssertEqual(AlertsPane.humanDuration(300), "5 minutes")
        XCTAssertEqual(AlertsPane.humanDuration(1800), "30 minutes")
        XCTAssertEqual(AlertsPane.humanDuration(5400), "1.5 hours")
    }

    func testHumanDurationDoesNotPrintANegativeInterval() {
        // Reachable via a hand-edited settings.json, which is user-facing
        // per SettingsStore's own doc comment.
        XCTAssertEqual(AlertsPane.humanDuration(-30), "Fires immediately")
    }

    // MARK: - Unit labels

    func testByteScaleUnitsGetAWordSinceTheirSuffixIsDeliberatelyEmpty() {
        XCTAssertEqual(MetricUnit.bytes.suffix, "", "precondition for this test")
        XCTAssertEqual(AlertsPane.unitLabel(.bytes), "bytes")
        XCTAssertEqual(AlertsPane.unitLabel(.percent), "%")
        XCTAssertEqual(AlertsPane.unitLabel(.thermalLevel), "0–3")
    }

    // MARK: - Condition summaries

    func testConditionSummaryForAPlaceholderRuleDescribesWhatIsActuallyMeasured() {
        let rules = AlertEngine.defaultRules(cooldown: 1800)
        let slowCharging = try? XCTUnwrap(rules.first { $0.id == AlertEngine.slowChargingRuleID })

        // Its stored condition reads "Charging ≤ 0 W", which is both false
        // and alarming; the summary must not repeat it.
        let summary = AlertsPane.conditionSummary(for: slowCharging!)
        XCTAssertEqual(summary, RuleKind.slowCharging.fixedConditionSummary)
        XCTAssertFalse(summary.contains("≤"))
    }

    func testConditionSummaryForAGenericRuleReadsAsTheComparison() {
        let rule = AlertRule(
            name: "Sustained high CPU",
            metric: .cpuTotalPercent,
            comparison: .above,
            threshold: 90,
            sustainedFor: 300,
            cooldown: 1800,
            actions: []
        )
        XCTAssertEqual(
            AlertsPane.conditionSummary(for: rule),
            "CPU ≥ \(MetricFormatter.detailed(90, unit: .percent))"
        )
    }
}
