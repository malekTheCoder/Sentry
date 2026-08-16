import XCTest
@testable import SentryKit

/// Unit tests for the read-side honesty judgments in
/// `SentryKit/Models/SleepAssertionDisplay.swift` — the predicates behind
/// the Control Center toggle's value, the widget sleep rows, and the phone
/// dashboard's card promotion. Pure value-in/verdict-out: every case is a
/// fabricated `SleepAssertionState` and a fabricated clock, no live
/// `IOPMAssertion` anywhere (that side is `PowerControlServiceTests`' job).
final class SleepAssertionDisplayTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func timed(endingIn seconds: TimeInterval) -> SleepAssertionState {
        .active(mode: .systemOnly, expiresAt: now.addingTimeInterval(seconds), reason: "test")
    }

    // MARK: - hasCertainlyEnded

    func testInactiveHasNotCertainlyEnded() {
        // "Ended" is a claim about a hold; no hold, no claim.
        XCTAssertFalse(SleepAssertionState.inactive.hasCertainlyEnded(asOf: now))
    }

    func testIndefiniteHoldNeverCertainlyEnds() {
        // The load-bearing asymmetry: an indefinite hold has no deadline in
        // the value, so no amount of elapsed time disproves it — a stale
        // reading must keep reporting it rather than fabricate a release
        // nobody observed.
        let indefinite = SleepAssertionState.active(mode: .displayAndSystem, expiresAt: nil, reason: "user")
        XCTAssertFalse(indefinite.hasCertainlyEnded(asOf: now))
        XCTAssertFalse(indefinite.hasCertainlyEnded(asOf: now.addingTimeInterval(365 * 24 * 3600)))
    }

    func testTimedHoldStillRunningHasNotEnded() {
        XCTAssertFalse(timed(endingIn: 60).hasCertainlyEnded(asOf: now))
    }

    func testTimedHoldPastDeadlineHasCertainlyEnded() {
        XCTAssertTrue(timed(endingIn: -1).hasCertainlyEnded(asOf: now))
    }

    func testDeadlineBoundaryCountsAsEnded() {
        // At exactly `expiresAt` the OS timeout has fired (the timeout is
        // armed *for* that instant) — `<=`, not `<`, so the boundary reads
        // as over rather than as one last second of claimed hold.
        let atBoundary = SleepAssertionState.active(mode: .systemOnly, expiresAt: now, reason: "test")
        XCTAssertTrue(atBoundary.hasCertainlyEnded(asOf: now))
    }

    // MARK: - isCrediblyActive

    func testInactiveIsNotCrediblyActive() {
        XCTAssertFalse(SleepAssertionState.inactive.isCrediblyActive(asOf: now))
    }

    func testRunningTimedHoldIsCrediblyActive() {
        XCTAssertTrue(timed(endingIn: 3600).isCrediblyActive(asOf: now))
    }

    func testExpiredTimedHoldIsNotCrediblyActive() {
        // The owner-scenario regression this whole helper exists for: a
        // cached `.active` past its own deadline must stop rendering as ON —
        // the recorded deadline released it whether or not the cache was
        // ever updated.
        XCTAssertFalse(timed(endingIn: -3600).isCrediblyActive(asOf: now))
    }

    func testStaleIndefiniteHoldStaysCrediblyActive() {
        // The counterpart guarantee: withdrawal only ever happens when the
        // data itself disproves the claim. A stale indefinite hold is
        // unknown, not off.
        let indefinite = SleepAssertionState.active(mode: .systemOnly, expiresAt: nil, reason: "user")
        XCTAssertTrue(indefinite.isCrediblyActive(asOf: now.addingTimeInterval(6 * 3600)))
    }
}
