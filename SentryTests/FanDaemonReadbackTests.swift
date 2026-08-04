import XCTest
@testable import SentryKit

/// The pure half of the fan-write readback-verification fix: whether a
/// sequence of post-write `F{i}Ac` samples counts as "the fan actually
/// moved," independent of any real SMC I/O.
///
/// **What this suite cannot cover, and why.** `SMCFanWriter.setTargetRPM` —
/// the caller that actually writes `F{i}Tg` and polls `F{i}Ac` — needs a
/// real, opened SMC user client and root, neither of which exists in a test
/// host (same constraint `SMCFanWriter`'s own header documents for every
/// write path). `FanDaemonReadback.applied` was factored out specifically
/// so the *decision* — does this set of numbers mean the fan moved — could
/// be exercised exhaustively without hardware, the same split
/// `FanDaemonClampTests` already relies on for the clamp decision one file
/// over.
final class FanDaemonReadbackTests: XCTestCase {

    // MARK: - Tolerance band: landed on target

    func testASampleWithinToleranceOfTargetIsApplied() {
        XCTAssertTrue(
            FanDaemonReadback.applied(target: 3000, initialRPM: 1500, samples: [2900, 3050])
        )
    }

    func testASampleExactlyOnTheToleranceBoundaryIsApplied() {
        let boundary = 3000 - FanDaemonReadback.toleranceRPM
        XCTAssertTrue(
            FanDaemonReadback.applied(target: 3000, initialRPM: 1500, samples: [boundary])
        )
    }

    func testOnlyTheLastSampleNeedsToBeInToleranceNotAll() {
        // A fan can overshoot or wobble mid-ramp; any sample landing in the
        // band during the poll window is evidence the target was reached at
        // some point, not just at the very end.
        XCTAssertTrue(
            FanDaemonReadback.applied(target: 3000, initialRPM: 1500, samples: [1800, 2200, 3010, 2850])
        )
    }

    // MARK: - Movement-toward-target, without ever entering the band

    func testMovementMeaningfullyTowardTargetCountsAsAppliedEvenShortOfTheBand() {
        // A large ramp (1200 -> 6000) that hasn't finished climbing by the
        // end of a ~1s poll window must not read as "thermalmonitord
        // overrode this" just because the fan is still accelerating.
        let farFromTolerance = 6000 - FanDaemonReadback.toleranceRPM - 500
        XCTAssertTrue(
            FanDaemonReadback.applied(target: 6000, initialRPM: 1200, samples: [2000, 3400, farFromTolerance])
        )
    }

    func testMovementBelowTheMinimumThresholdIsNotApplied() {
        // A wobble smaller than half the tolerance band must not be read as
        // forward progress — see `minimumMovementRPM`'s doc comment.
        let barelyMoved = 1200 + (FanDaemonReadback.minimumMovementRPM / 2)
        XCTAssertFalse(
            FanDaemonReadback.applied(target: 6000, initialRPM: 1200, samples: [barelyMoved])
        )
    }

    func testMovementAwayFromTargetIsNotApplied() {
        XCTAssertFalse(
            FanDaemonReadback.applied(target: 6000, initialRPM: 3000, samples: [2000, 1500])
        )
    }

    // MARK: - The exact "thermalmonitord silently won" case

    func testASampleStuckAtTheInitialValueIsNotApplied() {
        // The header case this whole fix exists for: the SMC accepted the
        // write, but the fan's actual RPM never moved at all.
        XCTAssertFalse(
            FanDaemonReadback.applied(target: 5000, initialRPM: 2000, samples: [2000, 2010, 1995, 2005])
        )
    }

    func testNoInitialReadingAndNoSampleInToleranceIsNotApplied() {
        // Without a baseline, "moved toward the target" is meaningless —
        // only the tolerance-band path can succeed, and here nothing is in
        // it.
        XCTAssertFalse(
            FanDaemonReadback.applied(target: 5000, initialRPM: nil, samples: [2000, 2010])
        )
    }

    // MARK: - Degenerate inputs

    func testNoSamplesAtAllIsNotApplied() {
        // Every readback in the poll window failed to decode — there is
        // nothing to credit as movement, regardless of target or baseline.
        XCTAssertFalse(FanDaemonReadback.applied(target: 3000, initialRPM: 1500, samples: []))
    }

    func testANonFiniteTargetIsNeverApplied() {
        XCTAssertFalse(
            FanDaemonReadback.applied(target: .nan, initialRPM: 1500, samples: [1500, 1500])
        )
        XCTAssertFalse(
            FanDaemonReadback.applied(target: .infinity, initialRPM: 1500, samples: [20_000])
        )
    }

    func testANonFiniteInitialReadingFallsBackToToleranceOnly() {
        // A garbage baseline must not crash the movement math; it should
        // simply make the movement path unavailable while leaving the
        // tolerance-band path intact.
        XCTAssertFalse(
            FanDaemonReadback.applied(target: 5000, initialRPM: .nan, samples: [2000])
        )
        XCTAssertTrue(
            FanDaemonReadback.applied(target: 5000, initialRPM: .nan, samples: [5010])
        )
    }

    // MARK: - FanWriteVerification

    func testNotAcceptedIsAlwaysBothFalseWithNoFinalRPM() {
        let outcome = FanWriteVerification.notAccepted
        XCTAssertFalse(outcome.accepted)
        XCTAssertFalse(outcome.applied)
        XCTAssertNil(outcome.finalRPM)
    }

    func testFanWriteVerificationCanExpressAcceptedButNotApplied() {
        // The exact combination `FanDaemonService.setTarget` must surface
        // distinctly rather than folding into an ordinary failure: the SMC
        // took the write, but the readback poll never confirmed movement.
        let outcome = FanWriteVerification(accepted: true, applied: false, finalRPM: 2005)
        XCTAssertTrue(outcome.accepted)
        XCTAssertFalse(outcome.applied)
        XCTAssertEqual(outcome.finalRPM, 2005)
    }
}
