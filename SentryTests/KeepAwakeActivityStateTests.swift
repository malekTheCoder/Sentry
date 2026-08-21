import XCTest
@testable import SentryKit

/// Unit tests for `KeepAwakeActivityState`
/// (`SentryKit/Models/KeepAwakeActivityState.swift`) — the content state of
/// the keep-awake Live Activity, and the one place the "what may a Lock
/// Screen claim about a Mac it cannot currently hear?" questions are
/// answered.
///
/// **What is deliberately not tested here, and why it cannot be.** Nothing
/// in this file touches ActivityKit, a real `Activity`, or a Mac. It cannot:
/// `SentryTests` is a macOS unit-test bundle (`project.yml`) and ActivityKit
/// does not exist on macOS at all. That constraint is the reason the model
/// was split the way it was — the fields, the timed-versus-indefinite fork,
/// the staleness arithmetic and the End-failure rule all live in a
/// Foundation-only file so they are reachable from here, while the
/// `ActivityAttributes` conformance next door is a typealias and two stored
/// properties with no logic to test.
final class KeepAwakeActivityStateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func timed(endingIn seconds: TimeInterval, confirmedAgo: TimeInterval = 0) -> KeepAwakeActivityState {
        KeepAwakeActivityState(
            mode: .systemOnly,
            expiresAt: now.addingTimeInterval(seconds),
            reason: "test",
            lastConfirmedAt: now.addingTimeInterval(-confirmedAgo)
        )
    }

    private func indefinite(confirmedAgo: TimeInterval = 0) -> KeepAwakeActivityState {
        KeepAwakeActivityState(
            mode: .displayAndSystem,
            expiresAt: nil,
            reason: "user",
            lastConfirmedAt: now.addingTimeInterval(-confirmedAgo)
        )
    }

    // MARK: - Indefinite vs timed

    func testIndefiniteIsExactlyTheAbsenceOfADeadline() {
        XCTAssertTrue(indefinite().isIndefinite)
        XCTAssertFalse(timed(endingIn: 60).isIndefinite)
    }

    func testTimedHoldStillRunningCountsDown() {
        guard case .countingDown(let until) = timed(endingIn: 3600).presentation(asOf: now) else {
            return XCTFail("A running timed hold must present as a live countdown")
        }
        XCTAssertEqual(until, now.addingTimeInterval(3600))
    }

    func testIndefiniteHoldNeverPresentsACountdown() {
        // The requirement in one assertion: an indefinite hold has no end to
        // count towards, so no amount of elapsed time may turn it into a
        // countdown or an "ended" claim.
        XCTAssertEqual(indefinite().presentation(asOf: now), .indefinite)
        XCTAssertEqual(
            indefinite(confirmedAgo: 365 * 24 * 3600).presentation(asOf: now.addingTimeInterval(365 * 24 * 3600)),
            .indefinite
        )
    }

    func testTimedHoldPastItsDeadlinePresentsAsEnded() {
        guard case .ended(let at) = timed(endingIn: -1).presentation(asOf: now) else {
            return XCTFail("An expired timed hold must not present as a countdown")
        }
        XCTAssertEqual(at, now.addingTimeInterval(-1))
    }

    func testDeadlineBoundaryPresentsAsEnded() {
        // `<=`, matching `SleepAssertionState.hasCertainlyEnded(asOf:)`'s own
        // boundary convention: the OS assertion timeout is armed *for* that
        // instant, so the boundary reads as over rather than as one last
        // second of claimed hold.
        let atBoundary = KeepAwakeActivityState(
            mode: .systemOnly,
            expiresAt: now,
            reason: "test",
            lastConfirmedAt: now
        )
        XCTAssertEqual(atBoundary.presentation(asOf: now), .ended(at: now))
    }

    // MARK: - Delegation to the shared honesty predicates

    func testHonestyPredicatesAreTheSharedOnes() {
        // These must not be a second implementation — the whole point of
        // `assertion` is that the Live Activity inherits the asymmetry
        // `SleepAssertionDisplay` encodes rather than re-deriving it.
        XCTAssertTrue(timed(endingIn: -1).hasCertainlyEnded(asOf: now))
        XCTAssertFalse(timed(endingIn: 1).hasCertainlyEnded(asOf: now))
        XCTAssertFalse(indefinite().hasCertainlyEnded(asOf: now.addingTimeInterval(1_000_000)))

        XCTAssertTrue(timed(endingIn: 1).isCrediblyActive(asOf: now))
        XCTAssertFalse(timed(endingIn: -1).isCrediblyActive(asOf: now))
        XCTAssertTrue(indefinite().isCrediblyActive(asOf: now.addingTimeInterval(1_000_000)))
    }

    func testAssertionRoundTripsTheHold() {
        guard case .active(let mode, let expiresAt, let reason) = timed(endingIn: 60).assertion else {
            return XCTFail("A state describes a hold, so its assertion is always .active")
        }
        XCTAssertEqual(mode, .systemOnly)
        XCTAssertEqual(expiresAt, now.addingTimeInterval(60))
        XCTAssertEqual(reason, "test")
    }

    // MARK: - Staleness

    func testKnownLossOfContactAgesTheActivityImmediately() {
        // The phone is not guessing — it watched the transport go down, so
        // there is nothing to wait out.
        XCTAssertEqual(timed(endingIn: 7200).staleDate(asOf: now, isMacReachable: false), now)
        XCTAssertEqual(indefinite().staleDate(asOf: now, isMacReachable: false), now)
    }

    func testTimedHoldStaysCurrentForItsWholeCountdown() {
        // The feature's central promise: a two-hour hold counts down for two
        // hours with no updates from anyone, because the deadline is carried
        // in the value and enforced by the Mac's OS-level assertion timeout.
        // Capping this at some tolerance after `lastConfirmedAt` would grey
        // out a countdown that is still correct.
        let twoHours = timed(endingIn: 7200, confirmedAgo: 1800)
        XCTAssertEqual(
            twoHours.staleDate(asOf: now, isMacReachable: true),
            now.addingTimeInterval(7200)
        )
    }

    func testIndefiniteHoldGoesStaleAfterItsConfirmationTolerance() {
        // Nothing self-carried backs an indefinite claim, so it expires with
        // the reading behind it.
        let state = indefinite(confirmedAgo: 0)
        XCTAssertEqual(
            state.staleDate(asOf: now, isMacReachable: true),
            now.addingTimeInterval(KeepAwakeActivityState.unconfirmedIndefiniteTolerance)
        )
    }

    func testIndefiniteToleranceIsTheCodebaseRecentThreshold() {
        // Pinned rather than assumed: this is the number that decides how
        // long a Lock Screen keeps vouching for a hold nobody has reheard,
        // and it is deliberately the same boundary every freshness badge in
        // the app already uses rather than one invented for this surface.
        XCTAssertEqual(KeepAwakeActivityState.unconfirmedIndefiniteTolerance, Freshness.recentThreshold)
    }

    func testStalenessIsMeasuredFromConfirmationNotFromNow() {
        // A hold last confirmed four minutes ago has one minute of
        // confidence left, not five.
        let state = indefinite(confirmedAgo: 240)
        XCTAssertEqual(
            state.staleDate(asOf: now, isMacReachable: true),
            now.addingTimeInterval(60)
        )
    }

    // MARK: - The End button's failure path

    func testConfirmedReleaseTellsTheCallerToEndTheActivity() {
        XCTAssertNil(timed(endingIn: 600).afterEndAttempt(.completed))
        XCTAssertNil(indefinite().afterEndAttempt(.completed))
    }

    func testFailedEndKeepsTheHoldAndAnnotatesIt() throws {
        // The rule this whole branch is judged on: a command with no
        // confirmed effect is never reported as success, and for a Live
        // Activity, vanishing *is* a success report.
        let before = timed(endingIn: 600)
        let after = try XCTUnwrap(before.afterEndAttempt(.noMacConnected))

        XCTAssertEqual(after.mode, before.mode, "A failed End must not alter the hold it failed to end")
        XCTAssertEqual(after.expiresAt, before.expiresAt)
        XCTAssertEqual(after.reason, before.reason)
        XCTAssertEqual(after.lastConfirmedAt, before.lastConfirmedAt)
        XCTAssertNotNil(after.endFailure)
    }

    func testEveryUnconfirmedOutcomeCarriesItsOwnSentence() throws {
        let outcomes: [KeepAwakeCommandOutcome] = [
            .declined("no adjustable assertion"),
            .unanswered,
            .notSent("connection reset"),
            .noMacConnected,
        ]
        var seen = Set<String>()
        for outcome in outcomes {
            let message = try XCTUnwrap(outcome.failureMessage, "\(outcome) must produce a message")
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(seen.insert(message).inserted, "Outcomes must stay distinguishable, not collapse into one apology")
        }
    }

    func testDeclinedOutcomeCarriesTheMacsOwnWords() throws {
        let message = try XCTUnwrap(KeepAwakeCommandOutcome.declined("nothing to release").failureMessage)
        XCTAssertTrue(message.contains("nothing to release"), "The Mac knows why it said no and this surface does not")
    }

    func testOnlyCompletedCountsAsConfirmed() {
        XCTAssertTrue(KeepAwakeCommandOutcome.completed.isConfirmed)
        XCTAssertNil(KeepAwakeCommandOutcome.completed.failureMessage)
        for outcome: KeepAwakeCommandOutcome in [.declined("x"), .unanswered, .notSent("x"), .noMacConnected] {
            XCTAssertFalse(outcome.isConfirmed)
        }
    }

    func testAnEmptyMacMessageStillProducesReadableCopy() throws {
        // `ControlStatus.message` is a wire field and can arrive empty; a
        // Lock Screen line reading "Your Mac declined that: " would be worse
        // than no detail at all.
        let declined = try XCTUnwrap(KeepAwakeCommandOutcome.declined("").failureMessage)
        XCTAssertFalse(declined.hasSuffix(": "))
        let notSent = try XCTUnwrap(KeepAwakeCommandOutcome.notSent("").failureMessage)
        XCTAssertFalse(notSent.hasSuffix("— "))
    }

    func testFreshNewsClearsAStaleEndFailure() throws {
        let annotated = try XCTUnwrap(timed(endingIn: 600).afterEndAttempt(.unanswered))
        XCTAssertNil(annotated.clearingEndFailure.endFailure)
    }

    // MARK: - Codable

    func testStateRoundTripsThroughCoding() throws {
        // Not ceremony: this value *is* an `ActivityAttributes.ContentState`,
        // which ActivityKit encodes and decodes across a process boundary on
        // every single update. A field that silently failed to survive that
        // would show up as a Lock Screen that never changes.
        for original in [timed(endingIn: 900, confirmedAgo: 30), indefinite(confirmedAgo: 5)] {
            let annotated = try XCTUnwrap(original.afterEndAttempt(.unanswered))
            let data = try JSONEncoder().encode(annotated)
            let decoded = try JSONDecoder().decode(KeepAwakeActivityState.self, from: data)
            XCTAssertEqual(decoded, annotated)
        }
    }
}
