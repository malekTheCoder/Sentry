import XCTest
@testable import SentryKit

/// Coverage for `Freshness` (`SentryKit/Sync/Freshness.swift`) — the iPhone
/// app's plan §12.2 "how old is this reading" bucketing. Pure function over
/// two `Date` values, same shape as `HeartbeatTrackerTests` (`HeartbeatTrackerTests.swift`),
/// whose boundary-testing convention (just-under / exactly / just-over each
/// threshold) this suite follows exactly.
final class FreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - .live: age < 60s

    func testZeroAgeIsLive() {
        XCTAssertEqual(Freshness(lastSeen: now, now: now), .live)
    }

    func testJustUnderSixtySecondsIsLive() {
        let lastSeen = now.addingTimeInterval(-(Freshness.liveThreshold - 1))
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .live)
    }

    func testFutureLastSeenIsLive() {
        // Defensive: a slightly-ahead device clock (or a heartbeat racing
        // this computation) shouldn't misclassify or crash on negative age.
        let lastSeen = now.addingTimeInterval(5)
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .live)
    }

    // MARK: - .recent: 60s <= age < 5min

    func testExactlySixtySecondsIsRecent() {
        let lastSeen = now.addingTimeInterval(-Freshness.liveThreshold)
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .recent)
    }

    func testJustUnderFiveMinutesIsRecent() {
        let lastSeen = now.addingTimeInterval(-(Freshness.recentThreshold - 1))
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .recent)
    }

    // MARK: - .stale: 5min <= age < 1hr

    func testExactlyFiveMinutesIsStale() {
        let lastSeen = now.addingTimeInterval(-Freshness.recentThreshold)
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .stale)
    }

    func testJustUnderOneHourIsStale() {
        let lastSeen = now.addingTimeInterval(-(Freshness.staleThreshold - 1))
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .stale)
    }

    // MARK: - .asleep: age >= 1hr

    func testExactlyOneHourIsAsleep() {
        let lastSeen = now.addingTimeInterval(-Freshness.staleThreshold)
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .asleep)
    }

    func testJustOverOneHourIsAsleep() {
        let lastSeen = now.addingTimeInterval(-(Freshness.staleThreshold + 1))
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .asleep)
    }

    func testFarInThePastIsAsleep() {
        let lastSeen = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(Freshness(lastSeen: lastSeen, now: now), .asleep)
    }

    // MARK: - Labels (plan §12.2's exact examples)

    func testLiveLabel() {
        XCTAssertEqual(Freshness.live.label(lastSeen: now, now: now), "Live")
    }

    func testRecentLabelFormatsMinutes() {
        let lastSeen = now.addingTimeInterval(-120) // 2 minutes
        XCTAssertEqual(Freshness.recent.label(lastSeen: lastSeen, now: now), "2m ago")
    }

    func testStaleLabelFormatsMinutes() {
        let lastSeen = now.addingTimeInterval(-18 * 60) // 18 minutes
        XCTAssertEqual(Freshness.stale.label(lastSeen: lastSeen, now: now), "18m ago")
    }

    func testAsleepLabelFormatsHoursWithPrefix() {
        let lastSeen = now.addingTimeInterval(-3 * 3600) // 3 hours
        XCTAssertEqual(
            Freshness.asleep.label(lastSeen: lastSeen, now: now),
            "Mac asleep — last seen 3h ago"
        )
    }

    // MARK: - Symbol names (plan §12.2: dot for live/recent/stale, moon for asleep)

    func testLiveRecentStaleUseDotSymbol() {
        XCTAssertEqual(Freshness.live.symbolName, "circle.fill")
        XCTAssertEqual(Freshness.recent.symbolName, "circle.fill")
        XCTAssertEqual(Freshness.stale.symbolName, "circle.fill")
    }

    func testAsleepUsesMoonSymbol() {
        XCTAssertEqual(Freshness.asleep.symbolName, "moon.fill")
    }

    // MARK: - warrantsCompactStalenessCue (ComplicationView.swift's dim/glyph cue)

    /// `.live` and `.recent` are the tiers a healthy relay passes through
    /// routinely — `WatchRelayPolicy.minimumRelayInterval` heartbeats every 5
    /// minutes even with nothing to report — so neither should trip a
    /// complication's staleness cue.
    func testLiveAndRecentDoNotWarrantAComplicationStalenessCue() {
        XCTAssertFalse(Freshness.live.warrantsCompactStalenessCue)
        XCTAssertFalse(Freshness.recent.warrantsCompactStalenessCue)
    }

    /// `.stale` (>= 5 minutes) is exactly the point at which the heartbeat
    /// itself has gone missing, which is the thing a compact complication
    /// family should flag.
    func testStaleAndAsleepWarrantAComplicationStalenessCue() {
        XCTAssertTrue(Freshness.stale.warrantsCompactStalenessCue)
        XCTAssertTrue(Freshness.asleep.warrantsCompactStalenessCue)
    }
}
