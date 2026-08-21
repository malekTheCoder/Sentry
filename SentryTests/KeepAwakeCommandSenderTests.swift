import XCTest
@testable import SentryKit

/// Unit tests for the parts of `KeepAwakeCommandSender`
/// (`SentryKit/Sync/KeepAwakeCommandSender.swift`) that can be pinned
/// without a Mac: the `ControlStatus`-to-outcome mapping, and the
/// `releaseAwake` command every End surface now shares.
///
/// **What is not tested, and why not.** `send(_:)` itself opens a real
/// `LocalSyncClient`, browses Bonjour, and waits on a socket. Exercising it
/// would need a live Mac running `LocalSyncServer` on the same network,
/// which is exactly the kind of test this project's suite does not have and
/// should not grow — `LocalSyncClientTests` and `LocalCommandExecutorTests`
/// already cover the transport and the Mac-side handler respectively, from
/// both ends, without one. What is left in the middle is the two pure pieces
/// below, and they are the ones that decide what a user is told.
final class KeepAwakeCommandSenderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func status(state: String, message: String = "") -> ControlStatus {
        ControlStatus(
            deviceID: "mac",
            respondsToNonce: "n",
            state: state,
            message: message,
            assertionActive: false,
            assertionExpiresAt: nil,
            updatedAt: now
        )
    }

    // MARK: - Reply mapping

    func testOnlyCompletedIsSuccess() {
        XCTAssertEqual(KeepAwakeCommandSender.outcome(for: status(state: "completed")), .completed)
    }

    func testRejectedCarriesTheMacsMessage() {
        XCTAssertEqual(
            KeepAwakeCommandSender.outcome(for: status(state: "rejected", message: "no adjustable assertion")),
            .declined("no adjustable assertion")
        )
    }

    func testExpiredIsNotSuccess() {
        XCTAssertFalse(KeepAwakeCommandSender.outcome(for: status(state: "expired")).isConfirmed)
    }

    func testAnUnrecognisedReplyStateIsNeverTreatedAsSuccess() {
        // `LocalSyncServer` also sends `accepted`, which means the command
        // was received and not that it worked. Anything this app does not
        // recognise has to fall on the not-confirmed side of the line: the
        // failure mode of guessing wrong here is a Lock Screen that
        // dismisses itself for a hold that is still running.
        for state in ["accepted", "", "queued", "🙂"] {
            XCTAssertFalse(
                KeepAwakeCommandSender.outcome(for: status(state: state)).isConfirmed,
                "\(state) must not read as success"
            )
        }
    }

    // MARK: - The release command

    func testReleaseCommandMatchesWhatEveryOtherSurfaceSends() throws {
        let command = KeepAwakeRequest.releaseCommand(now: now)
        XCTAssertEqual(command.commandType, "releaseAwake")
        XCTAssertEqual(command.parametersJSON, "{}")
        XCTAssertEqual(command.expiresAt, now.addingTimeInterval(KeepAwakeRequest.commandLifetime))
        XCTAssertEqual(command.issuedAt, now)
        // Empty object, not empty string — `LocalCommandExecutor` decodes
        // this field, and "" is not valid JSON.
        let object = try JSONSerialization.jsonObject(with: Data(command.parametersJSON.utf8))
        XCTAssertTrue(object is [String: Any])
    }

    func testEveryReleaseCommandGetsItsOwnNonce() {
        // The nonce is the Mac's idempotency key — it ignores one it has
        // already run. Two End taps sharing a nonce would mean the second
        // was silently discarded, and the Lock Screen would report a success
        // that came from the first.
        let nonces = Set((0..<8).map { _ in KeepAwakeRequest.releaseCommand().nonce })
        XCTAssertEqual(nonces.count, 8)
    }

    func testCommandLifetimeMatchesTheWindowEveryOtherSurfaceStamps() {
        XCTAssertEqual(KeepAwakeRequest.commandLifetime, 5 * 60)
    }

    // MARK: - The End button's failure path, end to end at the value level

    func testAnUnreachableMacLeavesTheActivityDescribingTheHold() throws {
        // This is the composed behaviour `EndKeepAwakeIntent.perform()`
        // produces: send, map the reply (or its absence) to an outcome, hand
        // the outcome to the state. The intent itself lives in an
        // ActivityKit-only file this macOS bundle cannot import, so the two
        // halves are tested where they live and the seam between them is one
        // line with nothing in it.
        let hold = KeepAwakeActivityState(
            mode: .systemOnly,
            expiresAt: now.addingTimeInterval(1800),
            reason: "Keeping your Mac awake",
            lastConfirmedAt: now
        )
        for outcome: KeepAwakeCommandOutcome in [.noMacConnected, .unanswered, .notSent("connection reset"), .declined("nope")] {
            let after = try XCTUnwrap(
                hold.afterEndAttempt(outcome),
                "\(outcome) must not dismiss the activity — a Live Activity that vanishes on tap is a success report"
            )
            XCTAssertEqual(after.expiresAt, hold.expiresAt)
            XCTAssertEqual(after.endFailure, outcome.failureMessage)
        }
    }

    func testAConfirmedReleaseIsTheOnlyThingThatDismissesTheActivity() {
        let hold = KeepAwakeActivityState(
            mode: .systemOnly,
            expiresAt: nil,
            reason: "Keeping your Mac awake",
            lastConfirmedAt: now
        )
        XCTAssertNil(hold.afterEndAttempt(KeepAwakeCommandSender.outcome(for: status(state: "completed"))))
    }
}
