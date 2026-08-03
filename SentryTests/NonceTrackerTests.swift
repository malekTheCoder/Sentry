import XCTest
@testable import SentryKit

/// Coverage for `NonceTracker` (`SentryKit/Sync/NonceTracker.swift`) —
/// idempotency + expiry gating for `ControlCommand`s per plan §10.4's
/// "Robustness requirements." All pure in-process logic; no CloudKit
/// involved.
@MainActor
final class NonceTrackerTests: XCTestCase {

    private func makeCommand(nonce: String, expiresAt: Date, issuedAt: Date = Date(timeIntervalSince1970: 0)) -> ControlCommand {
        ControlCommand(
            deviceID: "device-1",
            issuedAt: issuedAt,
            commandType: "keepAwake",
            parametersJSON: #"{"durationSeconds":3600,"mode":"system"}"#,
            nonce: nonce,
            expiresAt: expiresAt
        )
    }

    // MARK: - Basic dedup

    func testFreshNonceShouldExecute() {
        let tracker = NonceTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let command = makeCommand(nonce: "abc123", expiresAt: now.addingTimeInterval(300))
        XCTAssertTrue(tracker.shouldExecute(command, now: now))
    }

    func testDuplicateNonceRejectedOnSecondAttempt() {
        let tracker = NonceTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let command = makeCommand(nonce: "abc123", expiresAt: now.addingTimeInterval(300))

        XCTAssertTrue(tracker.shouldExecute(command, now: now))
        tracker.markExecuted(command.nonce)

        // A duplicated push must not restart the timer (plan §10.4).
        XCTAssertFalse(tracker.shouldExecute(command, now: now.addingTimeInterval(1)))
    }

    func testMarkExecutedIsIdempotent() {
        let tracker = NonceTracker()
        tracker.markExecuted("abc123")
        tracker.markExecuted("abc123")
        XCTAssertEqual(tracker.trackedCount, 1)
    }

    // MARK: - Expiry

    func testExpiredCommandRejected() {
        let tracker = NonceTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        // issued long ago (Mac was asleep), expiresAt already passed.
        let command = makeCommand(nonce: "stale-1", expiresAt: now.addingTimeInterval(-1))
        XCTAssertFalse(tracker.shouldExecute(command, now: now))
    }

    func testCommandExpiringExactlyNowIsRejected() {
        let tracker = NonceTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let command = makeCommand(nonce: "edge-1", expiresAt: now)
        // expiresAt <= now => rejected.
        XCTAssertFalse(tracker.shouldExecute(command, now: now))
    }

    func testCommandExpiringOneSecondFromNowIsAccepted() {
        let tracker = NonceTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let command = makeCommand(nonce: "edge-2", expiresAt: now.addingTimeInterval(1))
        XCTAssertTrue(tracker.shouldExecute(command, now: now))
    }

    // MARK: - 200-nonce FIFO bound

    func test201stDistinctNonceEvictsTheOldest() {
        let tracker = NonceTracker()
        for i in 0..<200 {
            tracker.markExecuted("nonce-\(i)")
        }
        XCTAssertEqual(tracker.trackedCount, 200)

        let now = Date(timeIntervalSince1970: 1_000_000)

        // "nonce-0" (the oldest) is still tracked -> still rejected.
        let oldest = makeCommand(nonce: "nonce-0", expiresAt: now.addingTimeInterval(300))
        XCTAssertFalse(tracker.shouldExecute(oldest, now: now))

        // Insert the 201st distinct nonce -> should evict "nonce-0".
        tracker.markExecuted("nonce-200")
        XCTAssertEqual(tracker.trackedCount, 200, "ring buffer must stay bounded at 200")

        // Documented accepted edge case: once evicted, a resend of the exact
        // same nonce is indistinguishable from a fresh command and would be
        // re-executed. This is intentional (see NonceTracker.markExecuted's
        // doc comment) — a real duplicate push does not realistically arrive
        // only after 200 other, distinct commands have executed since.
        let resent = makeCommand(nonce: "nonce-0", expiresAt: now.addingTimeInterval(300))
        XCTAssertTrue(
            tracker.shouldExecute(resent, now: now),
            "evicted nonces are treated as new again -- accepted tradeoff of a bounded ring buffer"
        )

        // The nonce that evicted it ("nonce-1", the next-oldest) is still tracked.
        let stillTracked = makeCommand(nonce: "nonce-1", expiresAt: now.addingTimeInterval(300))
        XCTAssertFalse(tracker.shouldExecute(stillTracked, now: now))
    }

    func testShouldExecuteDoesNotItselfMarkAsExecuted() {
        let tracker = NonceTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let command = makeCommand(nonce: "not-yet", expiresAt: now.addingTimeInterval(300))

        // Calling shouldExecute repeatedly (e.g. re-checked across multiple
        // poll ticks before the side effect actually runs) must not itself
        // consume the nonce.
        XCTAssertTrue(tracker.shouldExecute(command, now: now))
        XCTAssertTrue(tracker.shouldExecute(command, now: now))
        XCTAssertEqual(tracker.trackedCount, 0)
    }
}
