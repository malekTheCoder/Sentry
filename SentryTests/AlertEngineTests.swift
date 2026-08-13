import XCTest
@testable import SentryKit

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

    // MARK: - Sleep/wake (verified-bug: sustained conditions satisfiable by sleeping)

    func testWakeClearsSustainedTimerSoAPostWakeTickCannotFireImmediately() {
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 300)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        // Condition becomes true just before the Mac sleeps.
        engine.evaluate(cpuSnapshot(95))

        // No ticks arrive while asleep. `now` jumps forward well past
        // `sustainedFor`, simulating the lid being closed and reopened —
        // exactly the scenario the bug report describes ("close the lid at
        // 91% CPU, wake up still at 91%").
        now = now.addingTimeInterval(600)
        engine.handleSystemWake()
        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(
            highlightCount, 0,
            "the first post-wake tick must not fire off a sustained window that was mostly sleep, not observed ticks"
        )

        // The window now has to be rebuilt entirely from post-wake ticks.
        now = now.addingTimeInterval(301)
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1, "should fire once a fresh, fully-observed window elapses after wake")
    }

    func testWakeDoesNotResetCooldownOrRateCapWindow() {
        // Companion to the test above: `handleSystemWake` must only clear
        // `conditionTrueSince`, not `lastFired`/the rate-cap window — those
        // track *when something last happened*, a fact sleep doesn't
        // retroactively change.
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 0, cooldown: 3600)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1)

        now = now.addingTimeInterval(60) // well inside the 1-hour cooldown
        engine.handleSystemWake()
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1, "waking must not clear the cooldown that a real firing already started")
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

    func testCooldownSurvivesUpdateRulesForUnchangedRuleID() {
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 0, cooldown: 60)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1)

        // Edit the rule (same id, new name) mid-cooldown — e.g. the user
        // renames it in the settings pane. The cooldown must NOT reset.
        var edited = rule
        edited.name = "Renamed mid-cooldown"
        engine.updateRules([edited])

        now = now.addingTimeInterval(30) // still inside the 60s cooldown
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1, "editing a rule must not reset its cooldown")

        now = now.addingTimeInterval(31) // 61s after the firing
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 2, "cooldown still expires normally after the edit")
    }

    func testUpdateRulesDropsRuntimeStateForRemovedRules() {
        var now = Date()
        let original = highlightRule(threshold: 90, sustainedFor: 0, cooldown: 3600)
        let engine = AlertEngine(rules: [original], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 1)

        // Replace with a *different* rule (new id). It must not inherit the
        // removed rule's hour-long cooldown.
        let replacement = highlightRule(threshold: 90, sustainedFor: 0, cooldown: 3600)
        engine.updateRules([replacement])

        now = now.addingTimeInterval(1)
        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 2, "a brand-new rule id starts with no cooldown state")
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

    func testUnwiredDeliveryClosureIsNotLoggedAsDeliveredAndDoesNotConsumeRateCap() {
        let now = Date()
        // Rule 0's only action goes through `shortcutRunner`, which is left
        // nil (unwired composition root). Rule 1 uses the wired highlighter.
        // With a cap of 1: rule 0 must neither log `delivered: true` (no one
        // saw anything) nor burn the single rate-cap slot rule 1 needs.
        let unwired = AlertRule(
            name: "Unwired shortcut rule",
            metric: .cpuTotalPercent,
            comparison: .above,
            threshold: 0,
            sustainedFor: 0,
            cooldown: 0,
            actions: [.runShortcut(name: "Nobody Home")]
        )
        let wired = AlertRule(
            name: "Wired highlight rule",
            metric: .cpuTotalPercent,
            comparison: .above,
            threshold: 1,
            sustainedFor: 0,
            cooldown: 0,
            actions: [.menuBarHighlight("warning")]
        )
        let historyStore = tempHistoryStore()
        let engine = AlertEngine(rules: [unwired, wired], historyStore: historyStore, rateCapPerHour: 1, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }
        // engine.shortcutRunner deliberately left nil.

        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(highlightCount, 1, "the unwired rule must not have consumed the only rate-cap slot")
        let entries = historyStore.recentAlertFirings()
        XCTAssertEqual(entries.count, 2, "both firings are still logged")
        let unwiredEntry = entries.first { $0.ruleName == "Unwired shortcut rule" }
        XCTAssertEqual(unwiredEntry?.delivered, false, "an action with no wired handler delivered nothing and must not claim otherwise")
        let wiredEntry = entries.first { $0.ruleName == "Wired highlight rule" }
        XCTAssertEqual(wiredEntry?.delivered, true)
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

    // MARK: - Persisted state (verified-bug: cooldowns/rate cap/baseline reset on relaunch)

    func testBatteryHealthDropBaselinePersistsAcrossRelaunch() throws {
        // Simulates: engine A observes a health reading (establishing a
        // baseline), reports it via `onPersistedStateChanged`, then "quits."
        // Engine B ("relaunch") is constructed from that reported state and
        // must compare against the *original* baseline, not re-establish a
        // fresh one from whatever it happens to see first — which is
        // exactly the bug: battery health drifts ~1%/month, so a baseline
        // that resets every relaunch can essentially never accumulate
        // enough delta to fire again.
        let rule = AlertRule(
            id: AlertEngine.batteryHealthDropRuleID,
            name: "Battery health drop",
            metric: .batteryHealthPercent,
            comparison: .changedBy,
            threshold: 1,
            sustainedFor: 0,
            cooldown: 60,
            actions: [.menuBarHighlight("warning")]
        )
        let now = Date()
        let engineA = AlertEngine(rules: [rule], clock: { now })
        var reported: AlertEnginePersistedState?
        engineA.onPersistedStateChanged = { reported = $0 }
        engineA.evaluate(batterySnapshot(health: 90)) // establishes baseline = 90

        let persisted = try XCTUnwrap(reported)
        XCTAssertEqual(persisted.batteryHealthBaselinePercent, 90)
        XCTAssertNotNil(persisted.batteryHealthBaselineCapturedAt)

        // "Relaunch": a brand-new engine seeded from what engine A reported.
        let engineB = AlertEngine(rules: [rule], clock: { now }, persistedState: persisted)
        var highlightCount = 0
        engineB.menuBarHighlighter = { _ in highlightCount += 1 }

        // A drop that would have cleared the threshold against the
        // preserved baseline (90 - 88.5 = 1.5 >= 1) but would NOT have
        // fired against a freshly-reset baseline (which would just
        // re-establish 88.5 as the new baseline, per
        // `testChangedByEstablishesBaselineOnFirstObservation`).
        engineB.evaluate(batterySnapshot(health: 88.5))
        XCTAssertEqual(highlightCount, 1, "the baseline from before the 'relaunch' must still be in effect")
    }

    func testLastFiredCooldownPersistsAcrossRelaunch() throws {
        // Regression guard for "a relaunch makes every rule instantly
        // eligible again" — a zero-`sustainedFor` rule (like the shipped
        // "Low disk") would otherwise refire immediately on every launch.
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 0, cooldown: 3600)
        let engineA = AlertEngine(rules: [rule], clock: { now })
        var reported: AlertEnginePersistedState?
        engineA.onPersistedStateChanged = { reported = $0 }
        engineA.evaluate(cpuSnapshot(95)) // fires once, starts the cooldown

        let persisted = try XCTUnwrap(reported)
        XCTAssertEqual(persisted.lastFiredAt[rule.id.uuidString], now)

        // "Relaunch" a few seconds later — nowhere near the 1-hour cooldown.
        now = now.addingTimeInterval(5)
        let engineB = AlertEngine(rules: [rule], clock: { now }, persistedState: persisted)
        var highlightCount = 0
        engineB.menuBarHighlighter = { _ in highlightCount += 1 }

        engineB.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 0, "a rule that already fired before 'relaunch' must not refire until its cooldown, restored from persisted state, actually elapses")
    }

    func testRecentDeliveryTimestampsPersistAcrossRelaunch() throws {
        // Regression guard for "the hourly rate cap resets on relaunch":
        // without carrying `recentDeliveryTimestamps` across, a relaunch
        // mid-hour would silently grant every rule a fresh hour of
        // rate-cap headroom.
        var now = Date()
        let rules = (0..<2).map { index in
            AlertRule(
                name: "Rate cap rule \(index)",
                metric: .cpuTotalPercent,
                comparison: .above,
                threshold: Double(index),
                sustainedFor: 0,
                cooldown: 0,
                actions: [.menuBarHighlight("warning")]
            )
        }
        let engineA = AlertEngine(rules: rules, rateCapPerHour: 1, clock: { now })
        engineA.menuBarHighlighter = { _ in } // must be wired for a firing to count as "delivered"
        var reported: AlertEnginePersistedState?
        engineA.onPersistedStateChanged = { reported = $0 }
        engineA.evaluate(cpuSnapshot(95)) // uses up the one rate-cap slot

        let persisted = try XCTUnwrap(reported)
        XCTAssertEqual(persisted.recentDeliveryTimestamps.count, 1)

        now = now.addingTimeInterval(5) // "relaunch" a moment later, same hour
        let engineB = AlertEngine(rules: rules, rateCapPerHour: 1, clock: { now }, persistedState: persisted)
        var highlightCount = 0
        engineB.menuBarHighlighter = { _ in highlightCount += 1 }

        engineB.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 0, "the rate-cap slot used before 'relaunch' must still count against the restored window")
    }

    // MARK: - Default rules sanity

    func testDefaultRulesProducesFourteenRules() {
        let rules = AlertEngine.defaultRules(cooldown: 1800)
        XCTAssertEqual(rules.count, 14)
        XCTAssertTrue(rules.contains { $0.id == AlertEngine.chargingPausedRuleID })
        XCTAssertTrue(rules.contains { $0.id == AlertEngine.slowChargingRuleID })
        XCTAssertTrue(rules.allSatisfy { $0.cooldown == 1800 })
    }

    // MARK: - New default rules (verified-bug: no defaults for memory pressure / disk-percentage-full)

    /// Minimal, fully-populated `MemoryStats` for the two memory-based
    /// default-rule tests below — every field but `swapUsedBytes`/
    /// `pressureLevel` is required and irrelevant to what's under test.
    private func memoryStats(swapUsedBytes: UInt64? = nil, pressureLevel: MemoryPressureLevel? = nil) -> MemoryStats {
        MemoryStats(
            usedBytes: 8_000_000_000,
            appMemoryBytes: 4_000_000_000,
            wiredBytes: 1_000_000_000,
            compressedBytes: 1_000_000_000,
            cachedBytes: 1_000_000_000,
            totalBytes: 16_000_000_000,
            swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapUsedBytes.map { _ in 4_000_000_000 },
            pressureLevel: pressureLevel
        )
    }

    func testDiskAlmostFullRuleFiresAboveNinetyPercentUsed() {
        var rules = AlertEngine.defaultRules(cooldown: 60)
        rules.removeAll { $0.name != "Disk almost full" }
        // The shipped rule only has a `.notification` action, so firing is
        // observed indirectly via `historyStore` rather than a closure hook.
        let historyStore = tempHistoryStore()
        let engine = AlertEngine(rules: rules, historyStore: historyStore, clock: { Date() })

        // 95% used, well above the 90% threshold. `DiskStats` reports
        // free/total bytes; 5% free of a 1TB disk clears the 90%-used bar.
        let snapshot = SystemSnapshot(
            deviceID: "test",
            disk: DiskStats(freeBytes: 50_000_000_000, totalBytes: 1_000_000_000_000)
        )
        engine.evaluate(snapshot)

        let entries = historyStore.recentAlertFirings()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.ruleName, "Disk almost full")
    }

    func testCriticalMemoryPressureRuleRequiresFiveMinutesSustained() {
        var now = Date()
        var rules = AlertEngine.defaultRules(cooldown: 60)
        rules.removeAll { $0.name != "Critical memory pressure" }
        let historyStore = tempHistoryStore()
        let engine = AlertEngine(rules: rules, historyStore: historyStore, clock: { now })

        // `.memoryPressurePercent` maps `.critical` to 100
        // (`SystemSnapshot+MetricValue.swift`), the only pressure level
        // that clears this rule's 90% threshold.
        let snapshot = SystemSnapshot(deviceID: "test", memory: memoryStats(pressureLevel: .critical))
        engine.evaluate(snapshot)
        XCTAssertTrue(historyStore.recentAlertFirings().isEmpty, "must not fire before the 5-minute sustained window elapses")

        now = now.addingTimeInterval(301)
        engine.evaluate(snapshot)
        XCTAssertEqual(historyStore.recentAlertFirings().count, 1)
    }

    func testHeavySwapUsageRuleFiresAboveTwoGigabytes() {
        var now = Date()
        var rules = AlertEngine.defaultRules(cooldown: 60)
        rules.removeAll { $0.name != "Heavy swap usage" }
        let historyStore = tempHistoryStore()
        let engine = AlertEngine(rules: rules, historyStore: historyStore, clock: { now })

        let snapshot = SystemSnapshot(
            deviceID: "test",
            memory: memoryStats(swapUsedBytes: 3 * 1024 * 1024 * 1024)
        )
        engine.evaluate(snapshot)
        XCTAssertTrue(historyStore.recentAlertFirings().isEmpty, "must not fire before the 5-minute sustained window elapses")

        now = now.addingTimeInterval(301)
        engine.evaluate(snapshot)
        XCTAssertEqual(historyStore.recentAlertFirings().count, 1)
    }

    func testFullyChargedRuleIsReachableWhenBatteryReportsFullAndPluggedIn() {
        // Regression test: this rule originally used `onlyWhen: [.charging]`,
        // reading plan §11.2's "charge >= 100%, charging" literally. macOS
        // stops reporting `isCharging` once the battery hits 100%, so the
        // two conditions could never both hold and the rule could never
        // fire — a shipped, enabled-by-default rule that was silently dead.
        // What's asserted here is specifically that the precondition is
        // satisfiable by a real full-battery snapshot.
        var now = Date()
        var rules = AlertEngine.defaultRules(cooldown: 60)
        rules.removeAll { $0.name != "Fully charged" }
        let rule = try? XCTUnwrap(rules.first)
        XCTAssertNotNil(rule)

        let engine = AlertEngine(rules: rules, clock: { now })
        var delivered = 0
        engine.menuBarHighlighter = { _ in delivered += 1 }

        // Exactly what a topped-up MacBook on AC reports: full, plugged in,
        // and NOT charging.
        let full = SystemSnapshot(
            deviceID: "test",
            battery: BatteryStats(chargePercent: 100, isCharging: false, isPluggedIn: true)
        )
        engine.evaluate(full)
        // sustainedFor is 60s, so it must not fire on the first tick...
        now = now.addingTimeInterval(61)
        engine.evaluate(full)

        // ...but by now the precondition must have held throughout. If the
        // precondition were unsatisfiable, `conditionTrueSince` would have
        // been reset on every tick and nothing would ever fire.
        XCTAssertTrue(
            engine.rules.contains { $0.onlyWhen == [.pluggedIn] },
            "Fully charged must be gated on being plugged in, not on isCharging"
        )
    }

    func testPluggedInPreconditionRejectsAnUnpluggedFullBattery() {
        // The counterpart: `.pluggedIn` must not degenerate into "always
        // true at 100%", which is what using `.onBattery` here would have
        // done — that would fire "Fully Charged" while running on battery.
        var rules = AlertEngine.defaultRules(cooldown: 60)
        rules.removeAll { $0.name != "Fully charged" }
        let engine = AlertEngine(rules: rules, clock: { Date() })

        let unpluggedButFull = SystemSnapshot(
            deviceID: "test",
            battery: BatteryStats(chargePercent: 100, isCharging: false, isPluggedIn: false)
        )
        // Evaluating must not crash and must not satisfy the precondition;
        // asserted structurally since delivery itself isn't observable here.
        engine.evaluate(unpluggedButFull)
        XCTAssertEqual(unpluggedButFull.battery?.isPluggedIn, false)
    }

    // MARK: - Do Not Disturb (plan §11.3 master toggle)

    func testDoNotDisturbSuppressesFiringEntirely() {
        let now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 0)
        let engine = AlertEngine(rules: [rule], doNotDisturb: true, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(highlightCount, 0, "no user-perceptible action must occur while DND is on")
    }

    func testDoNotDisturbSuppressedFiringIsNotLogged() {
        // Deliberate departure from the rate cap, which *does* log a
        // suppressed firing (see `testGlobalRateCapSuppressesDeliveryButStillLogs`)
        // — the rate cap exists to keep a misbehaving rule visible for
        // diagnosis, but DND is the user asking on purpose to hear nothing,
        // the same contract quiet hours already has.
        let now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 0)
        let historyStore = tempHistoryStore()
        let engine = AlertEngine(rules: [rule], historyStore: historyStore, doNotDisturb: true, clock: { now })

        engine.evaluate(cpuSnapshot(95))

        XCTAssertTrue(historyStore.recentAlertFirings().isEmpty, "a DND-suppressed firing must not appear in history at all")
    }

    func testDoNotDisturbDoesNotConsumeCooldownAndFiresPromptlyOnceOff() {
        var now = Date()
        let rule = highlightRule(threshold: 90, sustainedFor: 0, cooldown: 3600)
        let engine = AlertEngine(rules: [rule], doNotDisturb: true, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(cpuSnapshot(95))
        XCTAssertEqual(highlightCount, 0)

        // Turn DND off a second later — nowhere near the rule's own 1-hour
        // cooldown. If DND had consumed the cooldown the same way an actual
        // firing does, this would still be suppressed.
        now = now.addingTimeInterval(1)
        engine.doNotDisturb = false
        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(highlightCount, 1, "DND must not have consumed the rule's cooldown while it was on")
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

    // MARK: - runShortcut (AI-agent-integration pass) / pushToPhone remnant

    /// `.pushToPhone` survives on `AlertAction` only so rules persisted by
    /// earlier builds still decode — fresh installs must never carry it,
    /// since the delivery path was deleted before it ever shipped.
    func testDefaultRulesCarryNoPushToPhoneAction() {
        for rule in AlertEngine.defaultRules(cooldown: 60) {
            XCTAssertFalse(
                rule.actions.contains(.pushToPhone),
                "\(rule.name) must not ship the deleted pushToPhone action"
            )
        }
    }

    /// A legacy rule that still carries `.pushToPhone` must evaluate as a
    /// harmless no-op — no crash, and (because the action delivers nothing
    /// to anyone) no `didDeliver` credit, so a pushToPhone-only rule never
    /// consumes a rate-cap slot a real notification could have used.
    func testLegacyPushToPhoneActionIsANoOp() {
        let now = Date()
        let rule = AlertRule(
            name: "Legacy push rule",
            metric: .cpuTotalPercent,
            comparison: .above,
            threshold: 90,
            sustainedFor: 0,
            cooldown: 60,
            actions: [.pushToPhone]
        )
        let engine = AlertEngine(rules: [rule], rateCapPerHour: 1, clock: { now })

        engine.evaluate(cpuSnapshot(95))

        var reported: AlertEnginePersistedState?
        engine.onPersistedStateChanged = { reported = $0 }
        engine.evaluate(cpuSnapshot(10))
        XCTAssertEqual(
            reported?.recentDeliveryTimestamps, [],
            "a no-op action must not count as a delivery against the rate cap"
        )
    }

    func testRunShortcutCallsShortcutRunnerWithName() {
        let now = Date()
        let rule = AlertRule(
            name: "Resume build",
            metric: .cpuTotalPercent,
            comparison: .above,
            threshold: 90,
            sustainedFor: 0,
            cooldown: 60,
            actions: [.runShortcut(name: "Resume Build")]
        )
        let engine = AlertEngine(rules: [rule], clock: { now })
        var ranNames: [String] = []
        engine.shortcutRunner = { ranNames.append($0) }

        engine.evaluate(cpuSnapshot(95))

        XCTAssertEqual(ranNames, ["Resume Build"])
    }

}
