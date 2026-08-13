import XCTest
@testable import SentryKit

/// Coverage for the process-scoped rule type added to `AlertEngine`
/// (`AlertRule.processNameMatch`, `AlertEngine.evaluateProcessRule`) — the
/// gap described in the task this pass closes: "a process pegging CPU for N
/// minutes" wasn't expressible as a rule because the data
/// (`SystemSnapshot.topProcesses`) didn't exist on the snapshot at all.
///
/// Structured like `AlertEngineTests` (menu-bar-highlight action so firing
/// is observable without touching the real `UNUserNotificationCenter`,
/// injected `clock` so sustained/cooldown timing doesn't need real
/// `sleep()` calls) rather than duplicating its whole fixture set — this
/// file only adds what's specific to the process path.
///
/// Every engine here passes `processRulesUnlocked: true` explicitly — the
/// parameter defaults to false (an unwired composition root must fail
/// toward *not* granting `ProFeature.processMatchAlerts`), and these tests
/// exercise the feature's behavior, not its gate. The gate itself is
/// pinned by the "Sentry Pro gate" section at the bottom.
@MainActor
final class ProcessAlertRuleTests: XCTestCase {

    // MARK: - Helpers

    private func processSnapshot(_ processes: [ProcessStats]?) -> SystemSnapshot {
        SystemSnapshot(deviceID: "test", topProcesses: processes)
    }

    private func process(name: String, pid: Int32 = 123, cpuPercent: Double = 0, residentMemoryBytes: UInt64 = 0) -> ProcessStats {
        ProcessStats(pid: pid, name: name, cpuPercent: cpuPercent, residentMemoryBytes: residentMemoryBytes)
    }

    private func processRule(
        name processName: String,
        metric: MetricID = .cpuTotalPercent,
        comparison: AlertRule.Comparison = .above,
        threshold: Double,
        sustainedFor: TimeInterval = 0,
        cooldown: TimeInterval = 60
    ) -> AlertRule {
        AlertRule(
            name: "Watch \(processName)",
            metric: metric,
            comparison: comparison,
            threshold: threshold,
            sustainedFor: sustainedFor,
            cooldown: cooldown,
            actions: [.menuBarHighlight("warning")],
            processNameMatch: processName
        )
    }

    // MARK: - Fires / doesn't fire

    func testFiresWhenNamedProcessCPUCrossesThreshold() {
        let rule = processRule(name: "node", threshold: 80)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 1)
    }

    func testDoesNotFireWhenNamedProcessCPUIsBelowThreshold() {
        let rule = processRule(name: "node", threshold: 80)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 10)]))

        XCTAssertEqual(highlightCount, 0)
    }

    func testMatchIsCaseInsensitive() {
        let rule = processRule(name: "Node", threshold: 80)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "NODE", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 1, "process name matching must be case-insensitive")
    }

    func testMemoryMetricComparesResidentMemoryNotCPU() {
        let rule = processRule(name: "node", metric: .memoryUsedBytes, threshold: 1_000_000_000)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        // High CPU, low memory: must not fire a memory-threshold rule.
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 100, residentMemoryBytes: 500)]))
        XCTAssertEqual(highlightCount, 0, "a memory rule must not fire off this process's CPU value")

        // Low CPU, high memory: must fire.
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 0, residentMemoryBytes: 2_000_000_000)]))
        XCTAssertEqual(highlightCount, 1)
    }

    func testDoesNotFireForADifferentlyNamedProcess() {
        let rule = processRule(name: "node", threshold: 10)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "python", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 0)
    }

    // MARK: - Honest-nil (P5): missing/unmeasured process data must never false-fire or crash

    func testDoesNotFireAndDoesNotCrashWhenTopProcessesHasNeverBeenCollected() {
        // `SystemSnapshot.topProcesses == nil` means the coordinator's
        // `.process` tier hasn't ticked yet this session — see that
        // property's doc comment. A rule referencing a process must treat
        // this as "condition not met," the same honest-nil contract every
        // other rule already has for a missing module.
        let rule = processRule(name: "node", threshold: 0) // threshold 0 would trivially "fire" on any real data
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot(nil))

        XCTAssertEqual(highlightCount, 0, "no process data yet must never read as the condition being met")
    }

    func testDoesNotFireWhenTopProcessesIsEmpty() {
        let rule = processRule(name: "node", threshold: 0)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([]))

        XCTAssertEqual(highlightCount, 0)
    }

    func testDoesNotFireWhenNamedProcessIsNotInTheTopNList() {
        // The named process is running but didn't crack the top-N-by-CPU
        // cut — a documented limitation (`SystemSnapshot.topProcesses`'s
        // doc comment), not a crash or a guess.
        let rule = processRule(name: "quiet-agent", threshold: 0)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "chrome", cpuPercent: 40), process(name: "xcodebuild", cpuPercent: 30)]))

        XCTAssertEqual(highlightCount, 0)
    }

    // MARK: - Sustained duration, specific to a process rule

    func testProcessRuleRespectsSustainedForBeforeFiring() {
        var now = Date()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 10)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        now = now.addingTimeInterval(5)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 0, "must not fire before sustainedFor elapses")

        now = now.addingTimeInterval(6)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1, "should fire once sustainedFor has elapsed")
    }

    func testProcessDroppingOutOfTheListResetsTheSustainedTimer() {
        // Same flap-suppression semantics every other rule already has
        // (`AlertEngineTests.testConditionGoingFalseResetsTheSustainedTimer`)
        // — here triggered by the process leaving the top-N list entirely,
        // not just its value dipping below threshold.
        var now = Date()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 10)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)])) // true at t0
        now = now.addingTimeInterval(5)
        engine.evaluate(processSnapshot([process(name: "chrome", cpuPercent: 50)])) // node vanished — resets
        now = now.addingTimeInterval(11)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)])) // true again, fresh window

        XCTAssertEqual(highlightCount, 0, "a tick where the named process isn't present must reset the sustained-since clock")

        now = now.addingTimeInterval(11)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1)
    }

    // MARK: - Cooldown, specific to a process rule

    func testProcessRuleRespectsCooldownBetweenFirings() {
        var now = Date()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 0, cooldown: 300)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1)

        now = now.addingTimeInterval(60)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1, "must not refire before cooldown elapses")

        now = now.addingTimeInterval(300)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 2, "should refire once cooldown has elapsed")
    }

    // MARK: - Participates in the shared pipeline like every other rule

    func testDoNotDisturbSuppressesAProcessRuleTheSameAsAnyOther() {
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 0)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        engine.doNotDisturb = true
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 0, "DND must gate a process rule exactly like every other rule")
    }

    func testDisabledProcessRuleNeverFires() {
        var rule = processRule(name: "node", threshold: 80, sustainedFor: 0)
        rule.isEnabled = false
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true)
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 0)
    }

    // MARK: - Sentry Pro gate (ProFeature.processMatchAlerts → AlertEngine.processRulesUnlocked)

    private func tempHistoryStore() -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessAlertRuleTests-\(UUID().uuidString).sqlite")
        return HistoryStore(databaseURL: url)
    }

    func testLockedProcessRuleNeverFiresLogsOrConsumesCooldown() {
        var now = Date()
        let historyStore = tempHistoryStore()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 0, cooldown: 300)
        // Deliberately no `processRulesUnlocked:` argument — this also pins
        // the default as false, the fail-toward-locked direction the
        // parameter's doc comment promises for an unwired composition root.
        let engine = AlertEngine(rules: [rule], historyStore: historyStore, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 0, "a locked process rule must never fire")
        XCTAssertTrue(
            historyStore.recentAlertFirings().isEmpty,
            "gated means not evaluated — nothing may reach alert_log, not even marked suppressed"
        )

        // The flip is live (same `var` convention as `doNotDisturb`), takes
        // effect on the next tick, and no cooldown was consumed while
        // locked: one second later is deep inside the 300 s cooldown, so
        // this firing proves the locked tick never touched `lastFired`.
        engine.processRulesUnlocked = true
        now = now.addingTimeInterval(1)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1, "unlock must take effect on the next tick, with no cooldown debt from locked ticks")
    }

    func testUnlockEvaluatesWithAFreshSustainedWindow() {
        // No sustained credit may accrue while locked — same "a window must
        // be built entirely from observed ticks" rule `handleSystemWake()`
        // enforces for sleep. The condition would have been true for the
        // whole locked stretch; none of it counts.
        var now = Date()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 10)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)])) // locked at t0
        now = now.addingTimeInterval(5)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)])) // locked at t5

        engine.processRulesUnlocked = true
        now = now.addingTimeInterval(1)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)])) // fresh window opens at t6
        now = now.addingTimeInterval(5)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)])) // t11 — 5 s into the window
        XCTAssertEqual(highlightCount, 0, "locked ticks must not count toward sustainedFor — t0..t5 is not credit")

        now = now.addingTimeInterval(6)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)])) // t17 — 11 s into the window
        XCTAssertEqual(highlightCount, 1, "should fire once the post-unlock window alone satisfies sustainedFor")
    }

    func testLockedEngineStillEvaluatesThresholdRulesUnchanged() {
        // The gate is scoped to `processNameMatch != nil` — an ordinary
        // metric/threshold rule on the same locked engine, evaluated from
        // the same snapshot, is entirely unaffected.
        let genericRule = AlertRule(
            name: "High CPU",
            metric: .cpuTotalPercent,
            comparison: .above,
            threshold: 90,
            sustainedFor: 0,
            cooldown: 60,
            actions: [.menuBarHighlight("generic")]
        )
        let engine = AlertEngine(rules: [genericRule, processRule(name: "node", threshold: 80)])
        var firedTokens: [String] = []
        engine.menuBarHighlighter = { firedTokens.append($0) }

        engine.evaluate(SystemSnapshot(
            deviceID: "test",
            cpu: CPUStats(totalPercent: 95),
            topProcesses: [process(name: "node", cpuPercent: 95)]
        ))

        XCTAssertEqual(firedTokens, ["generic"], "the threshold rule fires; the locked process rule stays silent")
    }

    func testLockingMidSessionStopsAnEnabledProcessRule() {
        // The lapse direction of the live flip: a rule that was firing
        // under a valid entitlement goes quiet the very next tick — never
        // "fired and suppressed", and never deleted.
        var now = Date()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 0, cooldown: 60)
        let engine = AlertEngine(rules: [rule], processRulesUnlocked: true, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1)

        engine.processRulesUnlocked = false
        now = now.addingTimeInterval(120) // well past cooldown — only the gate holds it back
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1, "a lapsed entitlement must stop firings on the next tick")
    }

    func testGatingNeverMutatesOrDeletesTheRule() {
        // The entitlement-lapse contract: rule data is the user's own and an
        // entitlement change may never edit or delete it. `AlertRule` is
        // `Equatable`, so this is a whole-value comparison, not a spot check.
        let rule = processRule(name: "node", threshold: 80)
        let engine = AlertEngine(rules: [rule])

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(engine.rules, [rule], "a locked evaluation must leave the rule untouched")

        engine.processRulesUnlocked = true
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(engine.rules, [rule], "unlocking and firing must leave the rule untouched too")
    }
}
