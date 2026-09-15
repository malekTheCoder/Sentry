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
/// Every engine here used to pass `processRulesUnlocked: true` explicitly,
/// because the parameter defaulted to false so an unwired composition root
/// would fail toward *not* granting `ProFeature.processMatchAlerts`. There
/// is no such parameter any more, and the plain constructors below are
/// themselves part of the point — see the "Ungated" section at the bottom.
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
        let engine = AlertEngine(rules: [rule])
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 1)
    }

    func testDoesNotFireWhenNamedProcessCPUIsBelowThreshold() {
        let rule = processRule(name: "node", threshold: 80)
        let engine = AlertEngine(rules: [rule])
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 10)]))

        XCTAssertEqual(highlightCount, 0)
    }

    func testMatchIsCaseInsensitive() {
        let rule = processRule(name: "Node", threshold: 80)
        let engine = AlertEngine(rules: [rule])
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "NODE", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 1, "process name matching must be case-insensitive")
    }

    func testMemoryMetricComparesResidentMemoryNotCPU() {
        let rule = processRule(name: "node", metric: .memoryUsedBytes, threshold: 1_000_000_000)
        let engine = AlertEngine(rules: [rule])
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
        let engine = AlertEngine(rules: [rule])
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
        let engine = AlertEngine(rules: [rule])
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot(nil))

        XCTAssertEqual(highlightCount, 0, "no process data yet must never read as the condition being met")
    }

    func testDoesNotFireWhenTopProcessesIsEmpty() {
        let rule = processRule(name: "node", threshold: 0)
        let engine = AlertEngine(rules: [rule])
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
        let engine = AlertEngine(rules: [rule])
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "chrome", cpuPercent: 40), process(name: "xcodebuild", cpuPercent: 30)]))

        XCTAssertEqual(highlightCount, 0)
    }

    // MARK: - Sustained duration, specific to a process rule

    func testProcessRuleRespectsSustainedForBeforeFiring() {
        var now = Date()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 10)
        let engine = AlertEngine(rules: [rule], clock: { now })
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
        let engine = AlertEngine(rules: [rule], clock: { now })
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
        let engine = AlertEngine(rules: [rule], clock: { now })
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
        let engine = AlertEngine(rules: [rule])
        engine.doNotDisturb = true
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 0, "DND must gate a process rule exactly like every other rule")
    }

    func testDisabledProcessRuleNeverFires() {
        var rule = processRule(name: "node", threshold: 80, sustainedFor: 0)
        rule.isEnabled = false
        let engine = AlertEngine(rules: [rule])
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))

        XCTAssertEqual(highlightCount, 0)
    }

    // MARK: - Ungated (the ex-paywall)

    private func tempHistoryStore() -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessAlertRuleTests-\(UUID().uuidString).sqlite")
        return HistoryStore(databaseURL: url)
    }

    /// **Process-match alerts genuinely work on a plain engine, and this is
    /// the proof.** Six tests used to sit here pinning
    /// `AlertEngine.processRulesUnlocked`: locked rules returned an
    /// honest-nil "condition not met", wrote nothing to `alert_log`,
    /// consumed no cooldown, and re-opened a fresh sustained window on
    /// unlock. There is no flag to set now — so the regression to guard
    /// against is the opposite one, an engine constructed the ordinary way
    /// that silently refuses process rules. This drives the full pipeline:
    /// fire, log, and cooldown, all from a default-constructed engine.
    func testADefaultEngineFiresLogsAndCoolsDownAProcessRule() {
        var now = Date()
        let historyStore = tempHistoryStore()
        let rule = processRule(name: "node", threshold: 80, cooldown: 300)
        let engine = AlertEngine(rules: [rule], historyStore: historyStore, clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1, "a process rule must fire on an engine nobody had to unlock")
        XCTAssertFalse(
            historyStore.recentAlertFirings().isEmpty,
            "the firing must reach alert_log — the gate used to keep it out entirely"
        )

        // Cooldown proves the firing was a real one that took the whole
        // pipeline, not a highlight that skipped the bookkeeping.
        now = now.addingTimeInterval(1)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1, "the 300 s cooldown must hold the second tick")
    }

    /// The sustained window is built from ordinary observed ticks, with no
    /// entitlement transition anywhere in it — the plain version of the
    /// fresh-window test the gate needed.
    func testSustainedWindowAccumulatesNormally() {
        var now = Date()
        let rule = processRule(name: "node", threshold: 80, sustainedFor: 10)
        let engine = AlertEngine(rules: [rule], clock: { now })
        var highlightCount = 0
        engine.menuBarHighlighter = { _ in highlightCount += 1 }

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        now = now.addingTimeInterval(5)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 0, "5 s is not yet the 10 s the rule asks for")

        now = now.addingTimeInterval(6)
        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(highlightCount, 1)
    }

    func testProcessAndThresholdRulesBothFireFromTheSameSnapshot() {
        // The gate was scoped to `processNameMatch != nil`, so a mixed
        // engine used to fire exactly one of these two. Both now.
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

        XCTAssertEqual(
            Set(firedTokens), ["generic", "warning"],
            "both rules must fire — the process one used to be the silent half"
        )
    }

    func testEvaluationNeverMutatesOrDeletesTheRule() {
        // Kept from the gate era, where it pinned that a lapse may not edit
        // user data. It still earns its place: `AlertRule` is `Equatable`,
        // so this is a whole-value assertion that evaluation is read-only.
        let rule = processRule(name: "node", threshold: 80)
        let engine = AlertEngine(rules: [rule])

        engine.evaluate(processSnapshot([process(name: "node", cpuPercent: 95)]))
        XCTAssertEqual(engine.rules, [rule])
    }
}
