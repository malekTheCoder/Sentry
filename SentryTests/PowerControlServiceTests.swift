import XCTest
@testable import SentryKit

/// Unit tests for `PowerControlService` (plan §10.1–§10.4). Covers the parts
/// that are pure logic and safe to exercise on a real Mac in a test host
/// process — the `ReleaseCondition` evaluators and the UserDefaults-backed
/// persistence/reconciliation round trip — using real `IOPMAssertion`
/// creation (per plan §10.1 this API is public, unprivileged, and safe to
/// call from a test host; every test releases what it creates so no test
/// leaves a stray sleep-prevention assertion alive past its own scope).
///
/// The whole class is `@MainActor` because `PowerControlService` itself is:
/// that keeps every call in these tests synchronously isolated to the same
/// actor as the service, with no `await` noise at each call site.
@MainActor
final class PowerControlServiceTests: XCTestCase {

    /// UserDefaults suite names created by `makeTestDefaults`, cleaned up in
    /// `tearDown()` so tests don't leave `~/Library/Preferences` plists
    /// behind across runs.
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    /// A fresh, isolated `UserDefaults` suite per test — mirrors
    /// `PowerControlService`'s injectable-`defaults:` convention (see its
    /// init doc comment referencing `RollupJob`) so these tests never touch
    /// `.standard` / real app persisted state.
    private func makeTestDefaults(_ name: String) -> UserDefaults {
        let suiteName = "dev.malekswilam.sentry.tests.PowerControlServiceTests.\(name).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func snapshot(cpuPercent: Double? = nil, batteryPercent: Double? = nil) -> SystemSnapshot {
        SystemSnapshot(
            deviceID: "test-device",
            battery: batteryPercent.map { BatteryStats(chargePercent: $0, isCharging: false, isPluggedIn: false) },
            cpu: cpuPercent.map { CPUStats(totalPercent: $0) }
        )
    }

    // MARK: - ReleaseCondition.cpuAbovePercent (sustained duration)

    func testCPUAbovePercentDoesNotReleaseBeforeSustainedWindowElapses() throws {
        let service = PowerControlService(defaults: makeTestDefaults("cpuNotYet"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .cpuAbovePercent(80, for: 0.3),
            reason: "cpu sustained test"
        )

        // Above threshold, but the sustained window hasn't elapsed yet —
        // must still be active.
        service.evaluate(snapshot(cpuPercent: 90))
        XCTAssertEqual(service.state, .active(mode: .systemOnly, expiresAt: nil, reason: "cpu sustained test"))
    }

    func testCPUAbovePercentDipResetsTheSustainedClock() throws {
        let service = PowerControlService(defaults: makeTestDefaults("cpuReset"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .cpuAbovePercent(80, for: 0.2),
            reason: "cpu reset test"
        )

        service.evaluate(snapshot(cpuPercent: 90))       // sustained clock starts
        Thread.sleep(forTimeInterval: 0.25)               // long enough to have fired...
        service.evaluate(snapshot(cpuPercent: 10))         // ...but a dip resets the clock
        service.evaluate(snapshot(cpuPercent: 90))         // freshly started again

        // Only ~0s has elapsed since the reset, well under the 0.2s window,
        // so this must still be active — proving the dip actually reset the
        // clock rather than the sustained window merely never having been
        // checked.
        XCTAssertNotEqual(service.state, .inactive)
    }

    func testCPUAbovePercentReleasesAfterHeldContinuouslyForFullWindow() throws {
        let service = PowerControlService(defaults: makeTestDefaults("cpuFires"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .cpuAbovePercent(80, for: 0.15),
            reason: "cpu fires test"
        )

        service.evaluate(snapshot(cpuPercent: 90))
        Thread.sleep(forTimeInterval: 0.2)
        service.evaluate(snapshot(cpuPercent: 90)) // still above threshold, window now elapsed

        XCTAssertEqual(service.state, .inactive)
    }

    // MARK: - ReleaseCondition.batteryBelowPercent

    func testBatteryBelowPercentStaysActiveAboveThresholdAndWithNoSample() throws {
        let service = PowerControlService(defaults: makeTestDefaults("batteryStaysActive"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .batteryBelowPercent(20),
            reason: "battery test"
        )

        // No battery sample on this snapshot at all (e.g. desktop Mac, or a
        // transient IOKit read failure per `BatteryStats`'s doc comment) —
        // must not crash and must not release.
        service.evaluate(snapshot())
        XCTAssertNotEqual(service.state, .inactive)

        // Above the threshold — stays active.
        service.evaluate(snapshot(batteryPercent: 55))
        XCTAssertNotEqual(service.state, .inactive)
    }

    func testBatteryBelowPercentReleasesWhenCrossed() throws {
        let service = PowerControlService(defaults: makeTestDefaults("batteryReleases"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .batteryBelowPercent(20),
            reason: "battery test"
        )

        service.evaluate(snapshot(batteryPercent: 55))
        XCTAssertNotEqual(service.state, .inactive)

        service.evaluate(snapshot(batteryPercent: 15))
        XCTAssertEqual(service.state, .inactive)
    }

    // MARK: - adjustAssertion(bySeconds:)

    func testAdjustAssertionExtendsRemainingDuration() throws {
        let service = PowerControlService(defaults: makeTestDefaults("adjustExtend"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "extend test")
        guard case .active(_, let before, _) = service.state, let before else {
            return XCTFail("expected a timed assertion")
        }

        try service.adjustAssertion(bySeconds: 300)

        guard case .active(let mode, let after, let reason) = service.state, let after else {
            return XCTFail("expected a timed assertion after extending")
        }
        XCTAssertEqual(mode, .systemOnly)
        XCTAssertEqual(reason, "extend test")
        // Allow slack for the wall-clock time elapsed between the two state reads.
        XCTAssertGreaterThan(after.timeIntervalSince(before), 290)
    }

    func testAdjustAssertionTruncatesRemainingDuration() throws {
        let service = PowerControlService(defaults: makeTestDefaults("adjustTruncate"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 600, reason: "truncate test")
        try service.adjustAssertion(bySeconds: -540)

        guard case .active(_, let after, _) = service.state, let after else {
            return XCTFail("expected a timed assertion after truncating")
        }
        let remaining = after.timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThan(remaining, 65)
    }

    func testAdjustAssertionTruncationBelowZeroReleasesImmediately() throws {
        let service = PowerControlService(defaults: makeTestDefaults("adjustTruncateToZero"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "truncate to zero test")
        try service.adjustAssertion(bySeconds: -600)

        XCTAssertEqual(service.state, .inactive)
    }

    // MARK: - Agent ownership survives extend/truncate (ownership-drift bug)

    func testAdjustAssertionExtendPreservesAgentOwnership() throws {
        // Before the fix, `adjustAssertion` called the untagged internal
        // start path directly, which bumps `assertionGeneration` and
        // silently detaches `agentOwnership` from the (now different)
        // generation — leaving an agent-held hold that the kill switch and
        // `AgentGuardrails.autoRevocationReason` can no longer see as
        // agent-owned. This is the exact scenario: extend an agent-held
        // assertion, then check the owner survived.
        let service = PowerControlService(defaults: makeTestDefaults("adjustAgentExtend"))
        defer { service.releaseAssertion() }

        try service.startAgentAssertion(
            mode: .systemOnly,
            duration: 60,
            reason: "agent hold",
            clientName: "claude-code"
        )
        XCTAssertEqual(service.agentAssertionOwner, "claude-code")
        let generationBeforeAdjust = service.assertionGeneration

        try service.adjustAssertion(bySeconds: 300)

        // The adjustment really did mint a new assertion (new generation) —
        // otherwise this test would trivially pass without exercising the
        // bug at all.
        XCTAssertNotEqual(service.assertionGeneration, generationBeforeAdjust)
        XCTAssertEqual(
            service.agentAssertionOwner,
            "claude-code",
            "extending an agent-held assertion must not silently strip its owner tag"
        )
    }

    func testAdjustAssertionTruncatePreservesAgentOwnership() throws {
        let service = PowerControlService(defaults: makeTestDefaults("adjustAgentTruncate"))
        defer { service.releaseAssertion() }

        try service.startAgentAssertion(
            mode: .systemOnly,
            duration: 600,
            reason: "agent hold",
            clientName: "codex"
        )
        XCTAssertEqual(service.agentAssertionOwner, "codex")

        try service.adjustAssertion(bySeconds: -540)

        guard case .active = service.state else {
            return XCTFail("truncating to a positive remainder must leave the assertion active")
        }
        XCTAssertEqual(
            service.agentAssertionOwner,
            "codex",
            "truncating an agent-held assertion must not silently strip its owner tag"
        )
    }

    func testAdjustAssertionOnAUserStartedAssertionStaysUnowned() throws {
        // The negative case: adjusting a hold nobody tagged as an agent's
        // must not fabricate an owner out of nowhere.
        let service = PowerControlService(defaults: makeTestDefaults("adjustUserOwned"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "user hold")
        try service.adjustAssertion(bySeconds: 120)

        XCTAssertNil(service.agentAssertionOwner)
    }

    // MARK: - Expiry-timer lifecycle races

    func testStaleExpiryTimerFireCannotReleaseASubsequentAssertion() throws {
        // The race: assertion A's timer fires and enqueues its release onto
        // the main actor; before that task runs, the user starts assertion B
        // (or extends A, which recreates it). The stale expiry must NOT tear
        // down B. Driven deterministically via the internal generation-
        // guarded landing point the timer block calls, rather than trying to
        // interleave a real Timer fire with a task hop.
        let service = PowerControlService(defaults: makeTestDefaults("staleTimer"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "assertion A")
        let staleGeneration = service.assertionGeneration

        try service.startAssertion(mode: .systemOnly, duration: 3600, reason: "assertion B")

        // Assertion A's timer fires late, carrying A's generation.
        service.timedAssertionExpired(generation: staleGeneration)
        guard case .active(_, _, let reason) = service.state else {
            return XCTFail("a stale expiry fire must not release the newer assertion")
        }
        XCTAssertEqual(reason, "assertion B")

        // The *current* generation's expiry still works — the guard must not
        // have turned real expiry into a no-op.
        service.timedAssertionExpired(generation: service.assertionGeneration)
        XCTAssertEqual(service.state, .inactive)
    }

    func testStaleExpiryTimerFireAfterManualReleaseIsHarmless() throws {
        let service = PowerControlService(defaults: makeTestDefaults("staleAfterRelease"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "released early")
        let generation = service.assertionGeneration
        service.releaseAssertion()

        // Idempotent: the stale fire lands on an already-inactive service.
        service.timedAssertionExpired(generation: generation)
        XCTAssertEqual(service.state, .inactive)
    }

    // MARK: - Degenerate durations

    func testZeroOrNegativeDurationDoesNotBecomeAnIndefiniteHold() throws {
        // A non-positive duration used to skip both the OS timeout and
        // `expiresAt`, silently producing an *indefinite* assertion — the
        // exact "Mac never sleeps again" failure mode the cold-start
        // reconciliation guard exists to prevent, minted fresh from a
        // degenerate input.
        let service = PowerControlService(defaults: makeTestDefaults("zeroDuration"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 0, reason: "zero seconds")
        XCTAssertEqual(service.state, .inactive, "a zero-length hold must hold nothing")

        try service.startAssertion(mode: .systemOnly, duration: -30, reason: "negative seconds")
        XCTAssertEqual(service.state, .inactive)

        // And it must still release any hold it replaced.
        try service.startAssertion(mode: .systemOnly, duration: 3600, reason: "real hold")
        try service.startAssertion(mode: .systemOnly, duration: 0, reason: "replaced by nothing")
        XCTAssertEqual(service.state, .inactive)
    }

    func testAdjustAssertionThrowsWhenNoAssertionActive() {
        let service = PowerControlService(defaults: makeTestDefaults("adjustNoneActive"))
        defer { service.releaseAssertion() }

        XCTAssertThrowsError(try service.adjustAssertion(bySeconds: 60)) { error in
            XCTAssertEqual(error as? PowerControlError, .noAdjustableAssertion)
        }
    }

    func testAdjustAssertionThrowsForIndefiniteAssertion() throws {
        let service = PowerControlService(defaults: makeTestDefaults("adjustIndefinite"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: nil, reason: "indefinite test")

        XCTAssertThrowsError(try service.adjustAssertion(bySeconds: 60)) { error in
            XCTAssertEqual(error as? PowerControlError, .noAdjustableAssertion)
        }
    }

    func testAdjustAssertionThrowsForConditionalAssertion() throws {
        let service = PowerControlService(defaults: makeTestDefaults("adjustConditional"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .batteryBelowPercent(20),
            reason: "conditional test"
        )

        XCTAssertThrowsError(try service.adjustAssertion(bySeconds: 60)) { error in
            XCTAssertEqual(error as? PowerControlError, .noAdjustableAssertion)
        }
    }

    // MARK: - Persistence / reconciliation round-trip

    func testReconciliationWithNoPersistedRecordStartsInactive() {
        let service = PowerControlService(defaults: makeTestDefaults("reconcileEmpty"))
        XCTAssertEqual(service.state, .inactive)
    }

    func testColdStartDoesNotRestoreAnIndefiniteAssertion() throws {
        let defaults = makeTestDefaults("reconcileIndefinite")

        let first = PowerControlService(defaults: defaults)
        try first.startAssertion(mode: .systemOnly, duration: nil, reason: "round trip")
        XCTAssertEqual(first.state, .active(mode: .systemOnly, expiresAt: nil, reason: "round trip"))

        // A second instance sharing the same UserDefaults suite simulates an
        // app relaunch. An *indefinite* assertion must NOT come back: the OS
        // released the real assertion when the previous process exited, so
        // the persisted record is only stale bookkeeping. Restoring it would
        // silently re-hold the machine awake with no user action — and,
        // because Sentry can be a login item, would do so on every boot,
        // forever, with nothing on screen until the user happens to open the
        // dropdown. Plan §10.4 only authorizes restoring a record whose
        // "expiry is still in the future," which an indefinite hold cannot
        // satisfy.
        let second = PowerControlService(defaults: defaults)
        XCTAssertEqual(second.state, .inactive)
        // The stale record must also be cleared, not left to be re-evaluated.
        XCTAssertNil(defaults.data(forKey: "dev.malekswilam.sentry.powercontrol.state"))

        first.releaseAssertion()
        second.releaseAssertion()
    }

    func testColdStartStillRestoresATimedAssertionWithItsRemainingWindow() throws {
        let defaults = makeTestDefaults("reconcileTimed")

        let first = PowerControlService(defaults: defaults)
        try first.startAssertion(mode: .systemOnly, duration: 3600, reason: "timed round trip")
        guard case .active(_, let firstExpiry, _) = first.state else {
            return XCTFail("expected the first service to hold an active assertion")
        }
        XCTAssertNotNil(firstExpiry)

        // The counterpart to the test above: a *timed* assertion is bounded
        // and self-releasing, so honouring the user's remaining window across
        // a relaunch can't strand the machine awake. This is the behaviour
        // the indefinite case deliberately diverges from, so it's asserted
        // explicitly rather than assumed.
        let second = PowerControlService(defaults: defaults)
        guard case .active(let mode, let secondExpiry, let reason) = second.state else {
            return XCTFail("expected a timed assertion to survive a cold start")
        }
        XCTAssertEqual(mode, .systemOnly)
        XCTAssertEqual(reason, "timed round trip")
        // Asserting the expiry is merely non-nil would also pass for an
        // implementation that restarted the *full* hour on every launch —
        // an assertion that renews itself indefinitely, which is the whole
        // failure mode the indefinite case above exists to prevent. The
        // distinguishing invariant is that restoring preserves the absolute
        // expiry *instant*; restarting would push it later.
        let secondExpiryUnwrapped = try XCTUnwrap(secondExpiry)
        let firstExpiryUnwrapped = try XCTUnwrap(firstExpiry)
        XCTAssertEqual(
            secondExpiryUnwrapped.timeIntervalSince(firstExpiryUnwrapped),
            0,
            accuracy: 1.0,
            "restoring must preserve the original expiry instant, not restart the window"
        )

        first.releaseAssertion()
        second.releaseAssertion()
    }

    func testColdStartRestoreOfATimedAgentHoldPreservesItsOwner() throws {
        // The cold-start counterpart to `testAdjustAssertion*PreservesAgentOwnership`:
        // `reconcilePersistedState` restores a timed hold via the same
        // untagged internal start path `adjustAssertion` used to, and
        // before `PersistedRecord.agentOwnerClientName` existed there was
        // nowhere for the owner to have survived a process relaunch at all
        // — the fresh process's in-memory `agentOwnership` starts `nil`
        // regardless of who held the assertion a moment ago.
        let defaults = makeTestDefaults("reconcileAgentColdStart")

        let first = PowerControlService(defaults: defaults)
        try first.startAgentAssertion(
            mode: .systemOnly,
            duration: 3600,
            reason: "agent hold across relaunch",
            clientName: "claude-code"
        )
        XCTAssertEqual(first.agentAssertionOwner, "claude-code")

        // A second instance sharing the same UserDefaults suite simulates a
        // relaunch, as in `testColdStartStillRestoresATimedAssertionWithItsRemainingWindow`.
        let second = PowerControlService(defaults: defaults)
        guard case .active = second.state else {
            return XCTFail("expected the timed hold to survive a cold start, per the existing restore behaviour")
        }
        XCTAssertEqual(
            second.agentAssertionOwner,
            "claude-code",
            "a restored agent-held timed hold must still be visible to the kill switch / guardrails as agent-owned"
        )

        first.releaseAssertion()
        second.releaseAssertion()
    }

    func testWakeReconcileOfAnAgentHoldPreservesItsOwner() throws {
        // The wake counterpart: the process never died, so `agentOwnership`
        // is still resident in memory, but `reconcilePersistedState` still
        // bumps `assertionGeneration` when it recreates the (already live)
        // OS assertion — see the type doc comment on why the wake path
        // recreates at all. Without re-tagging after that bump, the
        // in-memory tag would go stale on the very next guardrail check,
        // exactly as `adjustAssertion` did before its fix.
        let defaults = makeTestDefaults("reconcileAgentWake")
        let service = PowerControlService(defaults: defaults)
        try service.startAgentAssertion(
            mode: .systemOnly,
            duration: 3600,
            reason: "agent hold across wake",
            clientName: "claude-code"
        )
        let generationBeforeWake = service.assertionGeneration
        XCTAssertEqual(service.agentAssertionOwner, "claude-code")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let resumed = expectation(description: "wake reconciliation ran")
        DispatchQueue.main.async { resumed.fulfill() }
        wait(for: [resumed], timeout: 2)

        XCTAssertNotEqual(
            service.assertionGeneration,
            generationBeforeWake,
            "the wake path really does recreate the assertion (new generation) — otherwise this test wouldn't exercise the bug"
        )
        XCTAssertEqual(
            service.agentAssertionOwner,
            "claude-code",
            "waking must not silently strip an agent-held assertion's owner tag"
        )

        service.releaseAssertion()
    }

    func testWakeKeepsAnIndefiniteAssertionThatColdStartWouldHaveDiscarded() throws {
        let defaults = makeTestDefaults("reconcileWake")
        let service = PowerControlService(defaults: defaults)
        try service.startAssertion(mode: .systemOnly, duration: nil, reason: "across wake")

        // The deliberate asymmetry to `testColdStartDoesNotRestoreAnIndefiniteAssertion`:
        // on wake the process never died, so the user's standing "keep this
        // Mac awake" intent is still live and must survive. Only a cold
        // start — where the OS already released the real assertion — treats
        // the persisted record as stale. Without this test the two halves of
        // `isColdStart` could silently converge on the same behaviour and
        // still pass everything else.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let resumed = expectation(description: "wake reconciliation ran")
        DispatchQueue.main.async { resumed.fulfill() }
        wait(for: [resumed], timeout: 2)

        XCTAssertEqual(service.state, .active(mode: .systemOnly, expiresAt: nil, reason: "across wake"))

        service.releaseAssertion()
    }

    func testReconciliationDiscardsExpiredRecordInsteadOfRestoring() throws {
        let defaults = makeTestDefaults("reconcileExpired")
        let key = "dev.malekswilam.sentry.powercontrol.state"

        // Mirrors `PowerControlService`'s private `PersistedRecord` shape
        // exactly (same member names, same public Codable member types), so
        // encoding it here produces bytes the real service can decode. This
        // simulates a record left behind by a session that was killed
        // before its own in-process `Timer` could fire and clean up —
        // exactly the "sat around while the Mac was asleep/off" scenario
        // plan §10.4 calls out, applied to the local reconciliation path.
        struct MirrorRecord: Codable {
            var state: SleepAssertionState
            var condition: ReleaseCondition?
        }
        let expiredRecord = MirrorRecord(
            state: .active(mode: .systemOnly, expiresAt: Date().addingTimeInterval(-3600), reason: "stale"),
            condition: nil
        )
        defaults.set(try JSONEncoder().encode(expiredRecord), forKey: key)

        let service = PowerControlService(defaults: defaults)

        // Must not fire a fresh assertion for a window that already passed...
        XCTAssertEqual(service.state, .inactive)
        // ...and must not leave the stale record behind to fool the next launch.
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testReconciliationWithStaleAssertionIDDoesNotLeakOnMissingRecord() {
        // Regression test for the "no persisted record, but a live
        // assertion still exists in memory" edge case: reconciling must
        // route through the real release path (which clears `assertionID`)
        // rather than only overwriting `state`, or the in-memory bookkeeping
        // and the real OS-level assertion state can diverge silently.
        // Exercised indirectly here via the public API: starting an
        // indefinite assertion and then wiping the persisted record out
        // from under a still-live service (simulating persistence loss)
        // must not crash when reconciliation subsequently runs, and must
        // leave the service reporting `.inactive` afterward.
        let defaults = makeTestDefaults("reconcileStaleID")
        let service = PowerControlService(defaults: defaults)
        try? service.startAssertion(mode: .systemOnly, duration: nil, reason: "will be orphaned")
        XCTAssertNotEqual(service.state, .inactive)

        defaults.removeObject(forKey: "dev.malekswilam.sentry.powercontrol.state")

        // Directly re-invoke the same reconciliation `init` goes through,
        // via a fresh instance sharing the now-empty suite, confirming the
        // "no record" path is safe and terminal.
        let reconciled = PowerControlService(defaults: defaults)
        XCTAssertEqual(reconciled.state, .inactive)

        service.releaseAssertion()
        reconciled.releaseAssertion()
    }

    // MARK: - ReleaseCondition.whileProcessRunning

    func testProcessConditionHoldsWhileProbeSeesProcess() throws {
        let service = PowerControlService(defaults: makeTestDefaults("processHolds"))
        defer { service.releaseAssertion() }
        service.processProbe = { _ in true }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .whileProcessRunning(name: "claude"),
            reason: "process hold test"
        )
        service.evaluate(snapshot())
        service.evaluate(snapshot())
        XCTAssertNotEqual(service.state, .inactive)
    }

    func testProcessConditionSurvivesSingleMissThenReleasesOnSecond() throws {
        let service = PowerControlService(defaults: makeTestDefaults("processMissGrace"))
        defer { service.releaseAssertion() }
        var probeResults: [Bool] = [false, true, false, false]
        service.processProbe = { _ in probeResults.removeFirst() }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .whileProcessRunning(name: "claude"),
            reason: "process grace test"
        )
        // One miss: the grace window keeps the hold alive.
        service.evaluate(snapshot())
        XCTAssertNotEqual(service.state, .inactive)
        // The process reappears: the miss counter must reset…
        service.evaluate(snapshot())
        XCTAssertNotEqual(service.state, .inactive)
        // …so a single fresh miss still holds, and only the second
        // consecutive miss releases.
        service.evaluate(snapshot())
        XCTAssertNotEqual(service.state, .inactive)
        service.evaluate(snapshot())
        XCTAssertEqual(service.state, .inactive)
    }

    func testProcessMissCountDoesNotCarryAcrossReleaseAndRestart() throws {
        // A rapid release + re-arm must start the 2-miss grace window from
        // scratch: if the miss counter carried over, one miss before the
        // release plus one miss after it would sum to 2 and drop a
        // freshly-armed multi-hour hold on its first glitchy probe.
        let service = PowerControlService(defaults: makeTestDefaults("processMissReset"))
        defer { service.releaseAssertion() }
        service.processProbe = { _ in false }

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .whileProcessRunning(name: "claude"),
            reason: "first arm"
        )
        service.evaluate(snapshot()) // miss #1 under the first hold
        XCTAssertNotEqual(service.state, .inactive)

        service.releaseAssertion()

        try service.startConditionalAssertion(
            mode: .systemOnly,
            condition: .whileProcessRunning(name: "claude"),
            reason: "second arm"
        )
        service.evaluate(snapshot()) // miss #1 under the *second* hold
        XCTAssertNotEqual(
            service.state, .inactive,
            "a fresh hold must get its full 2-miss grace window, not inherit misses from a released one"
        )
        service.evaluate(snapshot()) // miss #2 — now it may release
        XCTAssertEqual(service.state, .inactive)
    }

    func testIsProcessRunningFindsThisTestHostAndNotNonsense() {
        // Whatever hosts this test bundle (xctest or the Sentry app) is
        // certainly running; an invented name is certainly not. Exercises
        // the real libproc scan, including its case-insensitivity.
        let hostName = ProcessInfo.processInfo.processName
        XCTAssertTrue(PowerControlService.isProcessRunning(named: hostName))
        XCTAssertTrue(PowerControlService.isProcessRunning(named: hostName.uppercased()))
        XCTAssertFalse(PowerControlService.isProcessRunning(named: "definitely-not-a-real-process-name"))
        XCTAssertFalse(PowerControlService.isProcessRunning(named: ""))
    }
}
