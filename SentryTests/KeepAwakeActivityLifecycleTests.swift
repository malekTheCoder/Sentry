import XCTest
@testable import SentryKit

/// Unit tests for `KeepAwakeActivityLifecycle`
/// (`SentryKit/Models/KeepAwakeActivityLifecycle.swift`) — the start /
/// update / end state machine behind the keep-awake Live Activity.
///
/// The machine was factored out of `KeepAwakeActivityController`
/// (`SentryMobile/LiveActivity/`) precisely so these cases could be written:
/// the controller does `Activity.request`/`update`/`end` and nothing else,
/// while every rule about *when* those happen is a pure function over two
/// values and a clock. Nothing below needs a Mac, a network, a running app,
/// or a real `Activity` — which is the only way the interesting question
/// ("does a hold the Mac stopped reporting leave a ghost on the Lock
/// Screen?") is answerable by a test at all.
final class KeepAwakeActivityLifecycleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func showing(
        expiresIn seconds: TimeInterval?,
        confirmedAgo: TimeInterval = 0,
        mode: AwakeMode = .systemOnly,
        reason: String = "test",
        endFailure: String? = nil
    ) -> KeepAwakeActivityState {
        KeepAwakeActivityState(
            mode: mode,
            expiresAt: seconds.map { now.addingTimeInterval($0) },
            reason: reason,
            lastConfirmedAt: now.addingTimeInterval(-confirmedAgo),
            endFailure: endFailure
        )
    }

    private func reported(expiresIn seconds: TimeInterval?, mode: AwakeMode = .systemOnly, reason: String = "test") -> SleepAssertionState {
        .active(mode: mode, expiresAt: seconds.map { now.addingTimeInterval($0) }, reason: reason)
    }

    private func next(
        showing: KeepAwakeActivityState? = nil,
        reported: SleepAssertionState? = nil,
        reportedAt: Date? = nil,
        isEnabled: Bool = true
    ) -> KeepAwakeActivityAction {
        KeepAwakeActivityLifecycle.next(
            showing: showing,
            reported: reported,
            reportedAt: reportedAt,
            isEnabled: isEnabled,
            now: now
        )
    }

    // MARK: - The opt-out

    func testDisabledEndsAnythingAlreadyRunning() {
        // "Off" means the Lock Screen row goes away, not that it freezes.
        // Leaving it up but un-updated would be the worst of both: a setting
        // that appears broken, and the un-updated surface this whole design
        // exists to avoid.
        let live = showing(expiresIn: 3600)
        XCTAssertEqual(next(showing: live, reported: reported(expiresIn: 3600), isEnabled: false), .end(live))
    }

    func testDisabledWithNothingRunningDoesNothing() {
        XCTAssertEqual(next(reported: reported(expiresIn: 3600), isEnabled: false), .none)
    }

    // MARK: - Ghosts

    func testExpiredActivityIsEndedEvenWithNoMacInEarshot() {
        // The app-was-killed case. ActivityKit keeps activities alive across
        // termination, so on relaunch the controller adopts whatever is on
        // screen — and a hold whose deadline passed while the process was
        // dead must be cleared without needing a Mac to be reachable, since
        // the OS-level assertion timeout already released it.
        let dead = showing(expiresIn: -60, confirmedAgo: 3600)
        XCTAssertEqual(next(showing: dead, reported: nil), .end(dead))
    }

    func testExpiredActivityIsEndedEvenIfTheMacStillReportsTheHold() {
        // The exact bug class this branch descends from: a Mac still
        // reporting `.active` for a hold whose recorded deadline has passed
        // is not evidence the hold is running — it is a snapshot that
        // predates the release.
        let dead = showing(expiresIn: -1)
        XCTAssertEqual(next(showing: dead, reported: reported(expiresIn: -1)), .end(dead))
    }

    func testMacReportingInactiveEndsTheActivity() {
        let live = showing(expiresIn: 3600)
        XCTAssertEqual(next(showing: live, reported: .inactive), .end(live))
    }

    func testInactiveWithNothingRunningDoesNothing() {
        XCTAssertEqual(next(reported: .inactive), .none)
    }

    // MARK: - Silence

    func testSilenceNeverStartsAnActivity() {
        // No news is not a hold.
        XCTAssertEqual(next(reported: nil), .none)
    }

    func testSilenceNeverEndsAnIndefiniteHold() {
        // The load-bearing asymmetry, inherited from `SleepAssertionDisplay`:
        // an indefinite hold has no deadline to disprove it and every path
        // that ends one happens on the Mac, out of sight. Ending the
        // activity here would fabricate a release nobody observed. The
        // activity stays and `staleDate` is what makes the system visibly
        // age it.
        let live = showing(expiresIn: nil, confirmedAgo: 7 * 24 * 3600)
        XCTAssertEqual(next(showing: live, reported: nil), .none)
    }

    func testSilenceDoesNotDisturbARunningTimedCountdown() {
        // The two-hour-countdown promise: a phone that has heard nothing for
        // half an hour still leaves a correct countdown alone.
        let live = showing(expiresIn: 5400, confirmedAgo: 1800)
        XCTAssertEqual(next(showing: live, reported: nil), .none)
    }

    // MARK: - Starting

    func testACrediblyLiveHoldStartsAnActivity() throws {
        let action = next(reported: reported(expiresIn: 3600))
        guard case .start(let state) = action else { return XCTFail("Expected .start, got \(action)") }
        XCTAssertEqual(state.mode, .systemOnly)
        XCTAssertEqual(state.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(state.lastConfirmedAt, now)
        XCTAssertNil(state.endFailure)
    }

    func testAnIndefiniteHoldStartsAnActivityWithNoDeadline() throws {
        let action = next(reported: reported(expiresIn: nil))
        guard case .start(let state) = action else { return XCTFail("Expected .start, got \(action)") }
        XCTAssertTrue(state.isIndefinite)
    }

    func testAnAlreadyExpiredHoldNeverOpensAnActivity() {
        // Opening one only to close it on the next tick would flash a Lock
        // Screen row for a session that was over before it was drawn.
        XCTAssertEqual(next(reported: reported(expiresIn: -1)), .none)
    }

    func testStartCarriesTheReadingsOwnTimestampNotTheWallClock() throws {
        // `lastConfirmedAt` is the anchor every staleness judgment is
        // measured from, so a reading that spent thirty seconds crossing
        // Wi-Fi must not be recorded as having arrived now.
        let takenAt = now.addingTimeInterval(-30)
        let action = next(reported: reported(expiresIn: nil), reportedAt: takenAt)
        guard case .start(let state) = action else { return XCTFail("Expected .start, got \(action)") }
        XCTAssertEqual(state.lastConfirmedAt, takenAt)
    }

    // MARK: - Updating

    func testExtendingAHoldUpdatesTheActivity() throws {
        let live = showing(expiresIn: 900)
        let action = next(showing: live, reported: reported(expiresIn: 900 + 3600))
        guard case .update(let state) = action else { return XCTFail("Expected .update, got \(action)") }
        XCTAssertEqual(state.expiresAt, now.addingTimeInterval(4500))
    }

    func testTruncatingAHoldUpdatesTheActivity() throws {
        let live = showing(expiresIn: 3600)
        let action = next(showing: live, reported: reported(expiresIn: 900))
        guard case .update(let state) = action else { return XCTFail("Expected .update, got \(action)") }
        XCTAssertEqual(state.expiresAt, now.addingTimeInterval(900))
    }

    func testChangingModeOrReasonUpdatesTheActivity() {
        let live = showing(expiresIn: 3600)
        XCTAssertNotEqual(next(showing: live, reported: reported(expiresIn: 3600, mode: .displayAndSystem)), .none)
        XCTAssertNotEqual(next(showing: live, reported: reported(expiresIn: 3600, reason: "different")), .none)
    }

    func testAnUnchangedTimedHoldDoesNotUpdateOnEverySnapshot() {
        // Snapshots arrive every few seconds. Comparing whole values —
        // `lastConfirmedAt` included — would mean an ActivityKit update per
        // tick for the life of every hold.
        let live = showing(expiresIn: 3600, confirmedAgo: 5)
        XCTAssertEqual(next(showing: live, reported: reported(expiresIn: 3600)), .none)
    }

    func testATimedHoldNeverHeartbeats() {
        // Its `staleDate` is its own deadline, indifferent to when the phone
        // last heard anything — so re-stamping `lastConfirmedAt` would cost
        // an update every two minutes and change nothing a viewer can see.
        let live = showing(expiresIn: 7200, confirmedAgo: 3600)
        XCTAssertEqual(next(showing: live, reported: reported(expiresIn: 7200)), .none)
    }

    func testAnIndefiniteHoldHeartbeatsBeforeItWouldGoStale() throws {
        let live = showing(expiresIn: nil, confirmedAgo: KeepAwakeActivityLifecycle.confirmationHeartbeat + 1)
        let action = next(showing: live, reported: reported(expiresIn: nil))
        guard case .update(let state) = action else { return XCTFail("Expected .update, got \(action)") }
        XCTAssertEqual(state.lastConfirmedAt, now)
    }

    func testAnIndefiniteHoldDoesNotHeartbeatBeforeItsInterval() {
        let live = showing(expiresIn: nil, confirmedAgo: KeepAwakeActivityLifecycle.confirmationHeartbeat - 1)
        XCTAssertEqual(next(showing: live, reported: reported(expiresIn: nil)), .none)
    }

    func testHeartbeatIntervalLeavesRoomBeforeTheStaleTolerance() {
        // If these were equal, a live, connected app would flicker in and
        // out of the system's stale treatment — training the user to ignore
        // the one signal that is supposed to mean something.
        XCTAssertLessThan(
            KeepAwakeActivityLifecycle.confirmationHeartbeat,
            KeepAwakeActivityState.unconfirmedIndefiniteTolerance
        )
    }

    func testStaleNewsCannotRepublishItselfAsAFreshConfirmation() {
        // The heartbeat compares confirmation to confirmation, not to the
        // wall clock. A Mac that has said nothing for an hour must not have
        // its hour-old reading re-stamped with the present time — that would
        // make the staleness machinery measure the controller's own pulse.
        let live = showing(expiresIn: nil, confirmedAgo: 3600)
        let staleNews = now.addingTimeInterval(-3600)
        XCTAssertEqual(
            next(showing: live, reported: reported(expiresIn: nil), reportedAt: staleNews),
            .none
        )
    }

    // MARK: - End failures

    func testFreshNewsSupersedesAFailedEndAttempt() throws {
        // A "couldn't reach your Mac" line sitting under a hold the phone is
        // currently hearing about is its own small lie.
        let complaining = showing(expiresIn: 3600, confirmedAgo: 5, endFailure: "Couldn't reach your Mac.")
        let action = next(showing: complaining, reported: reported(expiresIn: 3600))
        guard case .update(let state) = action else { return XCTFail("Expected .update, got \(action)") }
        XCTAssertNil(state.endFailure)
    }

    func testAFailedEndSurvivesUntilTheMacSaysSomething() {
        // Silence must not quietly erase the complaint either — the failure
        // is the most recent thing that actually happened.
        let complaining = showing(expiresIn: 3600, endFailure: "No Mac connected — nothing was sent.")
        XCTAssertEqual(next(showing: complaining, reported: nil), .none)
    }
}
