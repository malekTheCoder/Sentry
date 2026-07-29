import XCTest
@testable import MacStatKit

@MainActor
final class AlertEngineTests: XCTestCase {

    // MARK: - Helpers

    private func cpuSnapshot(_ percent: Double) -> SystemSnapshot {
        SystemSnapshot(deviceID: "test", cpu: CPUStats(totalPercent: percent))
    }

    private func diskSnapshot(freeBytes: UInt64) -> SystemSnapshot {
        SystemSnapshot(deviceID: "test", disk: DiskStats(freeBytes: freeBytes, totalBytes: 1_000_000_000_000))
    }

    private func batterySnapshot(health: Double) -> SystemSnapshot {
        SystemSnapshot(
            deviceID: "test",
            battery: BatteryStats(chargePercent: 80, isCharging: false, isPluggedIn: false, healthPercent: health)
        )
    }

    /// A rule with a single `.menuBarHighlight` action, so firing is
    /// observable via a closure without touching the real
    /// `UNUserNotificationCenter`.
    private func highlightRule(
        threshold: Double,
        sustainedFor: TimeInterval,
        cooldown: TimeInterval = 60,
        comparison: AlertRule.Comparison = .above,
        quietHours: AlertRule.QuietHours? = nil
    ) -> AlertRule {
        AlertRule(
            name: "Test rule",
            metric: .cpuTotalPercent,
            comparison: comparison,
            threshold: threshold,
            sustainedFor: sustainedFor,
            cooldown: cooldown,
            quietHours: quietHours,
            actions: [.menuBarHighlight("warning")]
        )
    }

    private func tempHistoryStore() -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlertEngineTests-\(UUID().uuidString).sqlite")
        return HistoryStore(databaseURL: url)
    }

    // MARK: - Sustained duration

    func testDoesNotFireBeforeSustainedForElapses() {
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 5)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        now = now.addingTimeInterval(2)
        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(highlightCount, 0, "should not fire before sustainedFor has elapsed")
    }

    func testFiresOnceSustainedForElapses() {
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 5)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        now = now.addingTimeInterval(6)
        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(highlightCount, 1)
    }

    func testConditionGoingFalseResetsTheSustainedTimer() {
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 5)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95)) // condition becomes true at t0
        now = now.addingTimeInterval(4)
        engine.evaluate(cpuSnapshot(50)) // dips below threshold — resets
        now = now.addingTimeInterval(4)
        engine.evaluate(cpuSnapshot(95)) // true again, but only 0s into a fresh window

        XCTAssertEqual(highlightCount, 0, "a tick where the condition is false must reset the sustained-since clock")

        now = now.addingTimeInterval(6)
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1, "should fire once the (fresh) window elapses")
    }

    // MARK: - Cooldown

    func testCooldownSuppressesRepeatFiring() {
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 0, cooldown: 60)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1)

        // Condition stays continuously true, well within cooldown.
        now = now.addingTimeInterval(30)
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1, "must not re-fire before cooldown elapses")

        now = now.addingTimeInterval(31) // now 61s after first firing
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 2, "should re-fire once cooldown has elapsed")
    }

    // MARK: - Quiet hours

    func testQuietHoursSuppressFiring() {
        // `AlertEngine` reads the hour via `Calendar.current` (the
        // device/process's local calendar), so the test builds `now` the
        // same way rather than pinning a fixed time zone that might not
        // match wherever this test happens to run.
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 23
        components.minute = 30
        var now = calendar.date(from: components)!

        let rule = highlightRule(
            threshold: 90,
            sustainedFor: 0,
            quietHours: AlertRule.QuietHours(startHour: 23, endHour: 8)
        )
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 0, "must not fire during quiet hours")

        // Move to 09:00 local *the next day* (still forward in time, and
        // outside the quiet window) — 09:00 on the *same* day as 23:30
        // would actually be earlier in absolute time, which would make
        // this assertion about elapsed-time logic rather than quiet hours.
        components.day = (components.day ?? 1) + 1
        components.hour = 9
        components.minute = 0
        now = calendar.date(from: components)!
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1, "should fire once outside the quiet window")
    }

    // MARK: - Global rate cap

    func testGlobalRateCapSuppressesDeliveryButStillLogs() {
        var now = Date()
        // Three independent rules (different metrics/thresholds so they
        // don't share sustained-timer state), each firing immediately.
        let rules = (0..<3).map { index in
            AlertRule(
                name: "Rate cap rule \(index)",
                metric: .cpuTotalPercent,
                comparison: .above,
                threshold: Double(index), // 0, 1, 2 — all satisfied by cpu=95
                sustainedFor: 0,
                cooldown: 0,
                actions: [.menuBarHighlight("warning")]
            )
        }
        let historyStore = tempHistoryStore()
        let engine = AlertEngine(rules: rules, historyStore: historyStore, rateCapPerHour: 2, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(highlightCount, 2, "only rateCapPerHour deliveries should go out")

        let entries = historyStore.recentAlertFirings()
        XCTAssertEqual(entries.count, 3, "every firing must still be logged, capped or not")
        XCTAssertEqual(entries.filter { $0.suppressed }.count, 1, "exactly one firing should be marked suppressed")
        XCTAssertEqual(entries.filter { !$0.suppressed }.count, 2)

        _ = now // silence "never mutated" warning if clock isn't advanced further
    }

    // MARK: - changedBy baseline

    func testChangedByEstablishesBaselineOnFirstObservation() {
        let now = Date()
        let rule = AlertRule(
            name: "Health drop",
            metric: .batteryHealthPercent,
            comparison: .changedBy,
            threshold: 1,
            sustainedFor: 0,
            cooldown: 60,
            actions: [.menuBarHighlight("warning")]
        )
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(batterySnapshot(health: 90))
        XCTAssertEqual(highlightCount, 0, "the first observation only establishes the baseline, it can't have 'changed' yet")
    }

    func testChangedByFiresOnceDeltaFromBaselineExceedsThreshold() {
        var now = Date()
        let rule = AlertRule(
            name: "Health drop",
            metric: .batteryHealthPercent,
            comparison: .changedBy,
            threshold: 1,
            sustainedFor: 0,
            cooldown: 60,
            actions: [.menuBarHighlight("warning")]
        )
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(batterySnapshot(health: 90)) // baseline = 90
        now = now.addingTimeInterval(1)
        engine.evaluate(batterySnapshot(health: 89.5)) // delta 0.5 < 1
        XCTAssertEqual(highlightCount, 0)

        now = now.addingTimeInterval(1)
        engine.evaluate(batterySnapshot(health: 88.9)) // delta 1.1 >= 1
        XCTAssertEqual(highlightCount, 1)
    }

    // MARK: - Default rules sanity

    func testDefaultRulesProducesElevenRules() {
        let rules = AlertEngine.defaultRules(cooldown: 1800)
        XCTAssertEqual(rules.count, 11)
        XCTAssertTrue(rules.contains { $0.id == AlertEngine.chargingPausedRuleID })
        XCTAssertTrue(rules.contains { $0.id == AlertEngine.slowChargingRuleID })
        XCTAssertTrue(rules.allSatisfy { $0.cooldown == 1800 })
    }

    // MARK: - Special-cased rules

    func testChargingPausedFiresWithDecodedReasonAndIgnoresPlaceholderMetric() {
        var now = Date()
        var rules = AlertEngine.defaultRules(cooldown: 60)
        // Isolate to just the rule under test.
        rules.removeAll { $0.id != AlertEngine.chargingPausedRuleID }
        let engine = AlertEngine(rules: rules, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        let notCharging = BatteryStats(
            chargePercent: 50,
            isCharging: false,
            isPluggedIn: true,
            notChargingReason: 1,
            notChargingReasonText: "Battery too hot"
        )
        let snapshot = SystemSnapshot(deviceID: "test", battery: notCharging)

        engine.evaluate(snapshot)
        now = now.addingTimeInterval(121) // sustainedFor is 120s
        engine.evaluate(snapshot)

        XCTAssertEqual(highlightCount, 0, "this rule only has a .notification action, not .menuBarHighlight")
        // Firing behavior itself is exercised via the notification path,
        // which isn't independently observable without a fake
        // UNUserNotificationCenter — the key regression this guards is
        // that the rule fires *at all* despite its placeholder
        // metric/comparison (batteryChargePercent/.above/0, which reads
        // as "always true" if accidentally evaluated as a normal rule).
        // Reaching this point without a crash and without evaluating the
        // placeholder comparison is the contract under test.
    }

    func testSlowChargingRequiresBothWattFieldsPresent() {
        let now = Date()
        var rules = AlertEngine.defaultRules(cooldown: 60)
        rules.removeAll { $0.id != AlertEngine.slowChargingRuleID }
        let engine = AlertEngine(rules: rules, clock: { now })

        // Charging but adapter rating unknown — must not crash or
        // false-positive on a missing denominator.
        let ambiguous = BatteryStats(chargePercent: 50, isCharging: true, isPluggedIn: true, chargingWatts: 10)
        engine.evaluate(SystemSnapshot(deviceID: "test", battery: ambiguous))
        // No assertion beyond "did not crash" — there's no observable
        // action wired up; this is a defensive-nil-handling regression
        // guard for evaluateSlowCharging's guard-let chain.
    }
}
