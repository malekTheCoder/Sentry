import XCTest
@testable import MacStatKit

/// Safety requirement 4, exhaustively: the state machine that decides when
/// a root process hands fans back to the firmware.
///
/// `FanDaemonFailSafe` takes its clock as a parameter specifically so this
/// suite exists — every window (15 s heartbeat, 60 s idle) can be driven to
/// its exact boundary in microseconds, with no sleeping and no flakiness.
final class FanDaemonFailSafeTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - The default state is "not holding anything"

    func testAFreshDaemonHoldsNothingAndHasNoClient() {
        let failSafe = FanDaemonFailSafe(startedAt: start)
        XCTAssertTrue(failSafe.heldFans.isEmpty)
        XCTAssertFalse(failSafe.hasConnectedClient)
        XCTAssertNil(failSafe.lastHeartbeat)
    }

    // MARK: - Heartbeat expiry

    func testAConnectionCountsAsProofOfLifeSoAFreshClientIsNotImmediatelyExpired() {
        // Without this, a client that connects and takes six seconds to
        // send its first beat would be judged against a nil last-beat.
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.clientConnected(at: at(0))
        XCTAssertNil(failSafe.dueTrigger(now: at(1)))
        XCTAssertEqual(failSafe.lastHeartbeat, at(0))
    }

    func testNothingFiresWhileTheClientKeepsCheckingIn() {
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.clientConnected(at: at(0))
        // Beat every 5 s (the shipped interval) for five minutes.
        for tick in stride(from: 5.0, through: 300.0, by: 5.0) {
            failSafe.heartbeat(at: at(tick))
            XCTAssertNil(
                failSafe.dueTrigger(now: at(tick + 4)),
                "a client beating on schedule must never be judged silent"
            )
        }
    }

    func testTheHeartbeatWindowIsThreeIntervalsWideAndInclusiveAtItsEdge() {
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.clientConnected(at: at(0))

        XCTAssertNil(failSafe.dueTrigger(now: at(14.9)), "one tick short must not fire")
        guard case .heartbeatExpired(let silence)? = failSafe.dueTrigger(now: at(15)) else {
            return XCTFail("expiry must fire at exactly the timeout, not one tick later")
        }
        XCTAssertEqual(silence, 15, accuracy: 0.001)
    }

    func testTheShippedIntervalLeavesRoomForTwoMissedBeats() {
        // The client's send interval and the daemon's expiry window are two
        // halves of one agreement; if they ever cross, every user sees fans
        // revert every few seconds. Asserted rather than left to comments.
        XCTAssertGreaterThanOrEqual(
            FanDaemonTiming.heartbeatTimeout,
            FanDaemonTiming.heartbeatInterval * 3
        )
        XCTAssertLessThan(
            FanDaemonTiming.heartbeatTimeout,
            FanDaemonTiming.idleExitAfter,
            "a wedged client's fans must be released long before the daemon would exit anyway"
        )
    }

    func testExpiryRevertsEverythingHeldAndDoesNotExit() {
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.clientConnected(at: at(0))
        failSafe.noteHoldingFan(1)
        failSafe.noteHoldingFan(0)

        guard let trigger = failSafe.dueTrigger(now: at(20)) else {
            return XCTFail("expected an expiry")
        }
        XCTAssertEqual(failSafe.fansToRevert(on: trigger), [0, 1], "sorted, and all of them")
        XCTAssertFalse(
            failSafe.shouldExit(after: trigger),
            "a wedged client may be about to recover; reverting is enough"
        )
    }

    func testADisconnectedClientIsNotJudgedOnItsHeartbeat() {
        // Otherwise a disconnect would produce a heartbeat expiry as well,
        // and the daemon would log two reverts for one event.
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.clientConnected(at: at(0))
        failSafe.clientDisconnected(at: at(1))
        XCTAssertNil(failSafe.dueTrigger(now: at(30)))
    }

    // MARK: - Disconnect

    func testDisconnectRevertsEverythingHeld() {
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.clientConnected(at: at(0))
        failSafe.noteHoldingFan(0)
        failSafe.clientDisconnected(at: at(5))
        XCTAssertEqual(failSafe.fansToRevert(on: .clientDisconnected), [0])
        XCTAssertFalse(failSafe.shouldExit(after: .clientDisconnected))
    }

    // MARK: - Idle exit (the leaked-daemon mitigation)

    func testADaemonNobodyEverDialedStillExitsOnSchedule() {
        // This is the shape a leaked daemon takes after the app is deleted:
        // launched once, never connected to. `startedAt` seeds the idle
        // clock precisely so this case is covered rather than living
        // forever as root.
        let failSafe = FanDaemonFailSafe(startedAt: start)
        XCTAssertNil(failSafe.dueTrigger(now: at(59)))
        guard case .idleWithNoClient(let idle)? = failSafe.dueTrigger(now: at(60)) else {
            return XCTFail("a daemon with no client must exit")
        }
        XCTAssertEqual(idle, 60, accuracy: 0.001)
        XCTAssertTrue(failSafe.shouldExit(after: .idleWithNoClient(idleFor: 60)))
    }

    func testTheIdleClockRestartsFromTheDisconnectNotFromDaemonStart() {
        // Otherwise a daemon that has been up for an hour would exit the
        // instant its client quit, and a relaunching app would find nothing
        // to reconnect to.
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.clientConnected(at: at(10))
        failSafe.clientDisconnected(at: at(3600))
        XCTAssertNil(failSafe.dueTrigger(now: at(3650)))
        XCTAssertNotNil(failSafe.dueTrigger(now: at(3660)))
    }

    func testIdleExitStillRevertsAnythingStillHeld() {
        // A disconnect should already have reverted these — but if that
        // write failed, the fan stays in `heldFans` and this is the retry.
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.noteHoldingFan(0)
        failSafe.clientDisconnected(at: at(0))
        guard let trigger = failSafe.dueTrigger(now: at(60)) else {
            return XCTFail("expected an idle exit")
        }
        XCTAssertEqual(failSafe.fansToRevert(on: trigger), [0])
    }

    // MARK: - Termination

    func testTerminationRevertsEverythingAndExits() {
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.noteHoldingFan(0)
        failSafe.noteHoldingFan(1)
        let trigger = FanDaemonRevertTrigger.daemonTerminating(signal: SIGTERM)
        XCTAssertEqual(failSafe.fansToRevert(on: trigger), [0, 1])
        XCTAssertTrue(failSafe.shouldExit(after: trigger))
    }

    // MARK: - Held-fan bookkeeping

    func testAFanIsForgottenOnlyWhenItIsActuallyGivenBack() {
        var failSafe = FanDaemonFailSafe(startedAt: start)
        failSafe.noteHoldingFan(0)
        failSafe.noteHoldingFan(0) // idempotent — a Set, not a counter
        XCTAssertEqual(failSafe.heldFans, [0])
        failSafe.noteReleasedFan(0)
        XCTAssertTrue(failSafe.heldFans.isEmpty)
        failSafe.noteReleasedFan(0) // releasing twice must not underflow
        XCTAssertTrue(failSafe.heldFans.isEmpty)
    }

    func testEveryTriggerRevertsEverythingHeldWithNoPartialSubset() {
        // A trigger that reverted "the fans this client took" would have to
        // trust a client-supplied list on exactly the path where the client
        // has already proven unreliable.
        var failSafe = FanDaemonFailSafe(startedAt: start)
        for index in 0..<4 { failSafe.noteHoldingFan(index) }
        let triggers: [FanDaemonRevertTrigger] = [
            .clientDisconnected,
            .heartbeatExpired(silentFor: 20),
            .daemonTerminating(signal: SIGTERM),
            .idleWithNoClient(idleFor: 60),
            .clientAskedForFirmware
        ]
        for trigger in triggers {
            XCTAssertEqual(failSafe.fansToRevert(on: trigger), [0, 1, 2, 3], "\(trigger)")
        }
    }

    func testRevertingNothingIsAValidOutcomeForEveryTrigger() {
        let failSafe = FanDaemonFailSafe(startedAt: start)
        XCTAssertTrue(failSafe.fansToRevert(on: .clientDisconnected).isEmpty)
        XCTAssertTrue(failSafe.fansToRevert(on: .daemonTerminating(signal: nil)).isEmpty)
    }

    // MARK: - Log copy

    func testEveryTriggerProducesALogLineThatNamesTheFansAndTheCause() {
        // Written before the reverts are attempted, so a daemon that dies
        // mid-revert still leaves evidence of what it was trying to do.
        let cases: [(FanDaemonRevertTrigger, String)] = [
            (.clientDisconnected, "disconnected"),
            (.heartbeatExpired(silentFor: 17.25), "heartbeat"),
            (.daemonTerminating(signal: SIGTERM), "signal 15"),
            (.idleWithNoClient(idleFor: 61), "No client"),
            (.clientAskedForFirmware, "firmware")
        ]
        for (trigger, needle) in cases {
            let line = FanDaemonFailSafe.logLine(for: trigger, fans: [0, 1])
            XCTAssertTrue(line.contains(needle), "\(trigger) → \(line)")
            XCTAssertTrue(line.contains("fan(s) 0, 1"), "\(trigger) → \(line)")
        }
        XCTAssertTrue(
            FanDaemonFailSafe.logLine(for: .clientDisconnected, fans: []).contains("no fans")
        )
    }

    // MARK: - Naming (the three strings that must agree with the plist)

    func testTheLabelPlistNameAndMachServiceAllDeriveFromOneConstant() {
        // The launchd plist's `Label` must equal its own file name minus
        // ".plist", and `SMAppService.daemon(plistName:)` looks the file up
        // by that name. Three separate literals drifted within an hour when
        // this was first written.
        XCTAssertEqual(FanDaemonNaming.label, "dev.malekswilam.macstat.fandaemon")
        XCTAssertEqual(FanDaemonNaming.plistName, "\(FanDaemonNaming.label).plist")
        XCTAssertEqual(FanDaemonNaming.machService, FanDaemonNaming.label)
    }
}
