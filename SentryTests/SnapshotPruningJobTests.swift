import XCTest
@testable import SentryKit

/// Coverage for `SnapshotPruningJob` (`SentryKit/Sync/SnapshotPruningJob.swift`)
/// — the 7-day retention decision from plan §7.4 ("Mac deletes `Snapshot`
/// records older than 7 days on each sync cycle"). Pure decision logic;
/// no CloudKit delete is ever attempted here.
final class SnapshotPruningJobTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(id: String, age: TimeInterval) -> SnapshotPruningJob.Candidate<String> {
        SnapshotPruningJob.Candidate(id: id, timestamp: now.addingTimeInterval(-age))
    }

    func testRecentSnapshotSurvives() {
        let candidates = [candidate(id: "recent", age: 60)]
        let pruned = SnapshotPruningJob.identifiersToPrune(candidates, now: now)
        XCTAssertTrue(pruned.isEmpty)
    }

    func testVeryOldSnapshotIsPruned() {
        let candidates = [candidate(id: "ancient", age: 30 * 24 * 60 * 60)]
        let pruned = SnapshotPruningJob.identifiersToPrune(candidates, now: now)
        XCTAssertEqual(pruned, ["ancient"])
    }

    // MARK: - Exact 7-day boundary

    func testJustUnderSevenDaysSurvives() {
        // 6d23h59m -> strictly within the window, must be kept.
        // Broken into pre-typed intermediate values rather than one long
        // integer-literal arithmetic chain: the latter is a known Swift
        // type-checker slow path (each `*`/`+` reopens overload resolution
        // across every numeric-literal-convertible type) that can time out
        // entirely rather than just being slow to compile.
        let sixDays: TimeInterval = 6 * 24 * 60 * 60
        let twentyThreeHours: TimeInterval = 23 * 60 * 60
        let fiftyNineMinutes: TimeInterval = 59 * 60
        let age: TimeInterval = sixDays + twentyThreeHours + fiftyNineMinutes
        let candidates = [candidate(id: "just-under", age: age)]
        XCTAssertTrue(SnapshotPruningJob.identifiersToPrune(candidates, now: now).isEmpty)
    }

    func testExactlySevenDaysSurvives() {
        // Exactly at the boundary instant -> kept ("older than 7 days," not
        // "7 days or older"), matching RollupJob's strict-inequality
        // convention (ts < cutoff).
        let candidates = [candidate(id: "exact", age: SnapshotPruningJob.retentionWindow)]
        XCTAssertTrue(SnapshotPruningJob.identifiersToPrune(candidates, now: now).isEmpty)
    }

    func testJustOverSevenDaysIsPruned() {
        // 7d00h01m -> just past the boundary, must be pruned.
        let age: TimeInterval = SnapshotPruningJob.retentionWindow + 60
        let candidates = [candidate(id: "just-over", age: age)]
        XCTAssertEqual(SnapshotPruningJob.identifiersToPrune(candidates, now: now), ["just-over"])
    }

    func testOneSecondPastBoundaryIsPruned() {
        let candidates = [candidate(id: "one-second-over", age: SnapshotPruningJob.retentionWindow + 1)]
        XCTAssertEqual(SnapshotPruningJob.identifiersToPrune(candidates, now: now), ["one-second-over"])
    }

    func testOneSecondBeforeBoundarySurvives() {
        let candidates = [candidate(id: "one-second-under", age: SnapshotPruningJob.retentionWindow - 1)]
        XCTAssertTrue(SnapshotPruningJob.identifiersToPrune(candidates, now: now).isEmpty)
    }

    // MARK: - Mixed batch

    func testMixedBatchPrunesOnlyStaleOnes() {
        let candidates = [
            candidate(id: "keep-1", age: 60),
            candidate(id: "prune-1", age: SnapshotPruningJob.retentionWindow + 3600),
            candidate(id: "keep-2", age: SnapshotPruningJob.retentionWindow - 3600),
            candidate(id: "prune-2", age: 14 * 24 * 60 * 60),
        ]
        let pruned = Set(SnapshotPruningJob.identifiersToPrune(candidates, now: now))
        XCTAssertEqual(pruned, ["prune-1", "prune-2"])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(SnapshotPruningJob.identifiersToPrune([SnapshotPruningJob.Candidate<String>](), now: now).isEmpty)
    }
}
