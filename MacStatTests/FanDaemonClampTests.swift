import XCTest
@testable import MacStatKit

/// Safety requirement 1, exhaustively.
///
/// This is the code that decides what number a **root process** writes to a
/// power controller, so it gets the density of coverage that implies rather
/// than the density its ~30 lines suggest. Every branch, every boundary, and
/// every degenerate input that could plausibly reach it from a hand-edited
/// settings file, a compromised client, or a misdecoded SMC read.
///
/// Note what is *not* mocked here: nothing. `FanDaemonClamp.resolve` is a
/// pure function over values, which is exactly why it could be lifted out of
/// the daemon at all — the daemon itself cannot be registered on this
/// machine (see `FanDaemonContract`), so anything left inside it is
/// unexercisable and everything moved out here is not.
final class FanDaemonClampTests: XCTestCase {

    private let ranges: [Int: FanRPMRange] = [
        // The spike's measured values on MacBookPro18,3 — two fans in one
        // laptop with ceilings 462 rpm apart, which is the whole reason
        // clamps come from hardware rather than a constant.
        0: FanRPMRange(minRPM: 1200, maxRPM: 5779),
        1: FanRPMRange(minRPM: 1200, maxRPM: 6241)
    ]

    private func resolve(_ rpm: Double, fan: Int = 0, fanCount: Int = 2) -> FanClampOutcome {
        FanDaemonClamp.resolve(rpm: rpm, forFan: fan, ranges: ranges, knownFanCount: fanCount)
    }

    // MARK: - The ordinary path

    func testARequestInsideTheRangeIsWrittenUnchangedAndNotReportedAsClamped() {
        XCTAssertEqual(resolve(3000), .write(rpm: 3000, wasClamped: false))
    }

    func testEachFanIsClampedToItsOwnCeilingNotASharedOne() {
        // The measured 462 rpm difference between the two fans of one
        // MacBook Pro, as a test. A shared constant would pass one of these
        // and fail the other.
        XCTAssertEqual(resolve(9000, fan: 0), .write(rpm: 5779, wasClamped: true))
        XCTAssertEqual(resolve(9000, fan: 1), .write(rpm: 6241, wasClamped: true))
    }

    func testBothBoundsAreInclusive() {
        XCTAssertEqual(resolve(1200), .write(rpm: 1200, wasClamped: false))
        XCTAssertEqual(resolve(5779), .write(rpm: 5779, wasClamped: false))
    }

    func testAJustOutOfRangeRequestIsClampedAndSaysSo() {
        XCTAssertEqual(resolve(1199), .write(rpm: 1200, wasClamped: true))
        XCTAssertEqual(resolve(5780), .write(rpm: 5779, wasClamped: true))
    }

    func testClampingIsReportedRatherThanSwallowed() {
        // A user who typed 8000 must be told their fan tops out at 5779.
        // `wasClamped` is the only thing that carries that.
        guard case .write(let rpm, let wasClamped) = resolve(8000) else {
            return XCTFail("expected a write")
        }
        XCTAssertEqual(rpm, 5779)
        XCTAssertTrue(wasClamped)
    }

    // MARK: - Below zero, and the direction that matters most

    func testAZeroRequestIsRaisedToTheHardwareFloorRatherThanStoppingTheFan() {
        // The single most dangerous request this feature can receive: stop
        // the fans on a hot Mac. The SMC's own `F{i}Mn` is the floor and
        // the daemon will not go below it, so "0 rpm" becomes "1200 rpm".
        XCTAssertEqual(resolve(0), .write(rpm: 1200, wasClamped: true))
    }

    func testANegativeRequestIsRaisedToTheFloorToo() {
        XCTAssertEqual(resolve(-5000), .write(rpm: 1200, wasClamped: true))
    }

    // MARK: - Refusals

    func testAnUnknownFanIsRefusedRatherThanClampedToSomeOtherFansRange() {
        XCTAssertEqual(resolve(3000, fan: 7), .refuse(.unknownFan(index: 7)))
        XCTAssertEqual(resolve(3000, fan: -1), .refuse(.unknownFan(index: -1)))
    }

    func testAFanBeyondTheReportedCountIsRefusedEvenIfARangeExistsForIt() {
        // `ranges` has an entry for fan 1, but `FNum` said there is only
        // one fan. The count wins: a stale range entry must not become a
        // writable fan.
        XCTAssertEqual(
            FanDaemonClamp.resolve(rpm: 3000, forFan: 1, ranges: ranges, knownFanCount: 1),
            .refuse(.unknownFan(index: 1))
        )
    }

    func testAFanWithNoReadableRangeIsRefusedRatherThanWrittenUnclamped() {
        // The bypass this whole design exists to prevent. "No limits, so
        // pass the request through" would make an unreadable SMC into a way
        // around the clamp entirely.
        let outcome = FanDaemonClamp.resolve(
            rpm: 3000,
            forFan: 0,
            ranges: [:],
            knownFanCount: 2
        )
        XCTAssertEqual(outcome, .refuse(.limitsUnreadable(index: 0)))
    }

    func testAnInvertedRangeIsRefusedRatherThanSilentlySwapped() {
        // Swapping min and max would turn a malfunctioning SMC read into a
        // plausible-looking bound that a root process then trusts.
        let inverted = [0: FanRPMRange(minRPM: 6000, maxRPM: 1200)]
        XCTAssertEqual(
            FanDaemonClamp.resolve(rpm: 3000, forFan: 0, ranges: inverted, knownFanCount: 1),
            .refuse(.limitsNonsensical(index: 0, minRPM: 6000, maxRPM: 1200))
        )
    }

    func testANegativeFloorIsRefused() {
        let negative = [0: FanRPMRange(minRPM: -100, maxRPM: 6000)]
        XCTAssertEqual(
            FanDaemonClamp.resolve(rpm: 3000, forFan: 0, ranges: negative, knownFanCount: 1),
            .refuse(.limitsNonsensical(index: 0, minRPM: -100, maxRPM: 6000))
        )
    }

    func testAnImplausiblyHighCeilingIsRefusedAsAMisdecode() {
        // A float that decodes to 4e38 is a misread field, not a fan.
        let absurd = [0: FanRPMRange(minRPM: 1200, maxRPM: 4e38)]
        guard case .refuse(.limitsNonsensical) = FanDaemonClamp.resolve(
            rpm: 3000, forFan: 0, ranges: absurd, knownFanCount: 1
        ) else {
            return XCTFail("an implausible ceiling must be refused, not used as a clamp bound")
        }
    }

    func testANonFiniteRangeIsRefused() {
        for bogus in [
            FanRPMRange(minRPM: .nan, maxRPM: 6000),
            FanRPMRange(minRPM: 1200, maxRPM: .infinity),
            FanRPMRange(minRPM: -.infinity, maxRPM: .infinity)
        ] {
            guard case .refuse(.limitsNonsensical) = FanDaemonClamp.resolve(
                rpm: 3000, forFan: 0, ranges: [0: bogus], knownFanCount: 1
            ) else {
                return XCTFail("non-finite limits must be refused: \(bogus)")
            }
        }
    }

    func testASingleSpeedFanIsValidAndClampsToItsOneValue() {
        // min == max is a real fan, not a broken read.
        let single = [0: FanRPMRange(minRPM: 2400, maxRPM: 2400)]
        XCTAssertEqual(
            FanDaemonClamp.resolve(rpm: 5000, forFan: 0, ranges: single, knownFanCount: 1),
            .write(rpm: 2400, wasClamped: true)
        )
    }

    func testNonFiniteRequestsAreRefusedRatherThanClampedToABound() {
        // `min(max(nan, lo), hi)` produces a number, which is exactly why
        // this is checked before the arithmetic rather than left to it.
        XCTAssertEqual(resolve(.nan), .refuse(.requestNotFinite))
        XCTAssertEqual(resolve(.infinity), .refuse(.requestNotFinite))
        XCTAssertEqual(resolve(-.infinity), .refuse(.requestNotFinite))
    }

    func testABadRequestAgainstABadFanBlamesTheFanFirst() {
        // Ordering matters for the message the user gets: "this Mac has no
        // fan 8" is actionable, "that isn't a real number" about a fan that
        // doesn't exist is not.
        XCTAssertEqual(
            FanDaemonClamp.resolve(rpm: .nan, forFan: 9, ranges: ranges, knownFanCount: 2),
            .refuse(.unknownFan(index: 9))
        )
    }

    // MARK: - Refusal copy

    func testEveryRefusalSaysSomethingSpecific() {
        let refusals: [FanDaemonRefusal] = [
            .unknownFan(index: 1),
            .limitsUnreadable(index: 0),
            .limitsNonsensical(index: 0, minRPM: 6000, maxRPM: 1200),
            .requestNotFinite,
            .smcWriteFailed(key: "F0Tg"),
            .peerRejected(reason: "not signed by this developer")
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty, "\(refusal)")
        }
        // Display ordinals are one-based for people, matching
        // `FanState.displayName` — the SMC's fan 1 is "Fan 2".
        XCTAssertTrue(FanDaemonRefusal.unknownFan(index: 1).message.contains("fan 2"))
        XCTAssertTrue(FanDaemonRefusal.smcWriteFailed(key: "F0Tg").message.contains("F0Tg"))
    }

    // MARK: - The command vocabulary itself

    func testTheCommandVocabularyCarriesNoRawKeyOrPayload() {
        // Not a behavioral test — a structural one. If someone adds a
        // `writeKey(String, [UInt8])` case to `FanDaemonCommand`, this stops
        // compiling, which is the earliest possible moment to notice that a
        // root daemon just grew an arbitrary-write primitive.
        let commands: [FanDaemonCommand] = [
            .setTarget(fanIndex: 0, requestedRPM: 3000),
            .returnToFirmware(fanIndex: 0),
            .describe
        ]
        for command in commands {
            switch command {
            case .setTarget, .returnToFirmware, .describe:
                XCTAssertFalse(command.logSummary.isEmpty)
            }
        }
    }

    func testTheLogSummaryRecordsWhatWasAskedForNotWhatWasWritten() {
        // A log that only recorded the clamped value could not show that a
        // client asked for something outrageous.
        XCTAssertTrue(
            FanDaemonCommand.setTarget(fanIndex: 0, requestedRPM: 99_000)
                .logSummary.contains("99000")
        )
    }
}
