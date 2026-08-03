import XCTest
@testable import SentryKit

/// Coverage for `HeartbeatTracker` (`SentryKit/Sync/HeartbeatTracker.swift`)
/// — the Mac-side "should I be in fast-cadence mode" decision from plan
/// §7.4. Pure function over two `Date` values; no CloudKit, no `Device`
/// dependency (see that file's doc comment for why: `Device` doesn't have
/// `lastViewedAt` yet).
final class HeartbeatTrackerTests: XCTestCase {

    func testNilLastViewedAtIsNotFastCadence() {
        XCTAssertFalse(HeartbeatTracker.isFastCadence(lastViewedAt: nil, now: Date()))
    }

    func testJustViewedIsFastCadence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(HeartbeatTracker.isFastCadence(lastViewedAt: now, now: now))
    }

    func testJustUnderTenMinutesIsFastCadence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lastViewedAt = now.addingTimeInterval(-(HeartbeatTracker.fastCadenceWindow - 1))
        XCTAssertTrue(HeartbeatTracker.isFastCadence(lastViewedAt: lastViewedAt, now: now))
    }

    func testExactlyTenMinutesIsNotFastCadence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lastViewedAt = now.addingTimeInterval(-HeartbeatTracker.fastCadenceWindow)
        XCTAssertFalse(HeartbeatTracker.isFastCadence(lastViewedAt: lastViewedAt, now: now))
    }

    func testJustOverTenMinutesIsNotFastCadence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lastViewedAt = now.addingTimeInterval(-(HeartbeatTracker.fastCadenceWindow + 1))
        XCTAssertFalse(HeartbeatTracker.isFastCadence(lastViewedAt: lastViewedAt, now: now))
    }

    func testFutureLastViewedAtIsFastCadence() {
        // Defensive: a slightly-ahead device clock shouldn't crash or flip
        // negative math into "not fast cadence" incorrectly.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lastViewedAt = now.addingTimeInterval(5)
        XCTAssertTrue(HeartbeatTracker.isFastCadence(lastViewedAt: lastViewedAt, now: now))
    }
}
