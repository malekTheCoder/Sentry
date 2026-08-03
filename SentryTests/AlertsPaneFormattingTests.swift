import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the pure display logic in `AlertsPane`
/// (Sentry/Settings/Panes/AlertsPane.swift). None of this draws anything —
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

    // MARK: - Byte-scale threshold editor/summary agreement

    func testThresholdEditorAndSummaryAgreeOnAByteScaleValue() {
        // Regression test for the reviewer-observed bug: the editable field
        // showed the raw stored bytes ("10000000000", unit "bytes") while
        // the row summary/footer showed `MetricFormatter.detailed`'s
        // divided-by-1024³ "9.31 GB" for the very same stored value. Both
        // now go through the same GB conversion.
        let storedBytes = 10_000_000_000.0
        let editorValue = AlertsPane.gbValue(fromBytes: storedBytes)
        let summaryText = AlertsPane.detailedThreshold(storedBytes, unit: .bytes)

        XCTAssertEqual(editorValue, storedBytes / (1024 * 1024 * 1024), accuracy: 0.0001)
        XCTAssertTrue(
            summaryText.hasPrefix(String(format: "%.2f", editorValue)),
            "summary '\(summaryText)' must describe the same number the editor shows (\(editorValue))"
        )
        XCTAssertEqual(AlertsPane.thresholdUnitLabel(.bytes), "GB")
    }

    func testByteScaleThresholdRoundTripsThroughTheGBConversion() {
        let originalBytes = 1_073_741_824.0 // exactly 1 GiB
        let gb = AlertsPane.gbValue(fromBytes: originalBytes)
        XCTAssertEqual(gb, 1, accuracy: 0.0001)
        XCTAssertEqual(AlertsPane.bytes(fromGB: gb), originalBytes, accuracy: 0.5)
    }

    func testShippedLowDiskThresholdFormatsAsACleanTenGB() {
        // The shipped default is defined in binary GiB specifically so this
        // reads "10 GB", not the odd "9.31 GB" a decimal-billion threshold
        // would produce through the same 1024-based formatter.
        let rules = AlertEngine.defaultRules(cooldown: 1800)
        let lowDisk = try? XCTUnwrap(rules.first { $0.name == "Low disk" })
        XCTAssertEqual(
            AlertsPane.detailedThreshold(lowDisk!.threshold, unit: .bytes),
            "10 GB"
        )
    }

    func testDetailedThresholdFallsBackToMetricFormatterForNonByteUnits() {
        XCTAssertEqual(
            AlertsPane.detailedThreshold(90, unit: .percent),
            MetricFormatter.detailed(90, unit: .percent)
        )
    }

    // MARK: - Adding a new rule

    func testNewRuleGetsAFreshIDDistinctFromTheReservedSpecialCasedIDs() {
        let rule = AlertsPane.makeNewRule(cooldown: 1800)
        XCTAssertNotEqual(rule.id, AlertEngine.chargingPausedRuleID)
        XCTAssertNotEqual(rule.id, AlertEngine.slowChargingRuleID)
        XCTAssertNotEqual(rule.id, AlertEngine.batteryHealthDropRuleID)
    }

    func testNewRuleIsMeaningfulOnItsOwn() {
        // A rule needs a metric, comparison, threshold, sustainedFor,
        // cooldown, and at least one action to actually do anything — an
        // empty-actions rule would fire and be silently useless.
        let rule = AlertsPane.makeNewRule(cooldown: 1800)
        XCTAssertFalse(rule.actions.isEmpty, "a new rule with no actions fires and does nothing")
        XCTAssertEqual(rule.cooldown, 1800, "cooldown must come from the caller's current setting, not a baked-in literal")
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(RuleKind(id: rule.id), .generic, "a new rule must take the generic evaluation path, not collide with a special-cased one")
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
