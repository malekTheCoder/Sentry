import XCTest
@testable import SentryKit

/// Unit tests for `AgentSessionRegistry`: registration/refresh semantics,
/// the recent-tools ring, lazy expiry at `staleAfter`, caller exclusion, and
/// single-holder keep-awake attribution. All time flows through the `at:`/
/// `asOf:` parameters, so nothing here sleeps or depends on the wall clock.
///
/// `@MainActor` because the registry is — same convention as
/// `PowerControlServiceTests`.
@MainActor
final class AgentSessionRegistryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Register / update

    func testFirstCallCreatesSession() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "Claude Code", tool: .getSystemSnapshot, at: t0)

        let sessions = registry.activeSessions(asOf: t0)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].clientName, "Claude Code")
        XCTAssertEqual(sessions[0].connectedAt, t0)
        XCTAssertEqual(sessions[0].lastCallAt, t0)
        XCTAssertEqual(sessions[0].recentTools, [.getSystemSnapshot])
        XCTAssertFalse(sessions[0].holdsKeepAwake)
    }

    func testLaterCallUpdatesLastCallButKeepsConnectedAt() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "Claude Code", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "Claude Code", tool: .preflightCheck, at: t0.addingTimeInterval(60))

        let session = registry.activeSessions(asOf: t0.addingTimeInterval(60))[0]
        XCTAssertEqual(session.connectedAt, t0)
        XCTAssertEqual(session.lastCallAt, t0.addingTimeInterval(60))
        XCTAssertEqual(session.recentTools, [.preflightCheck, .getSystemSnapshot])
    }

    func testRecentToolsDeduplicatesToFront() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "c", tool: .preflightCheck, at: t0)
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0)

        XCTAssertEqual(registry.activeSessions(asOf: t0)[0].recentTools, [.getSystemSnapshot, .preflightCheck])
    }

    func testRecentToolsIsCapped() {
        let registry = AgentSessionRegistry()
        for tool in MCPToolID.allCases {
            registry.recordCall(clientName: "c", tool: tool, at: t0)
        }
        let tools = registry.activeSessions(asOf: t0)[0].recentTools
        XCTAssertEqual(tools.count, AgentSessionRegistry.recentToolsLimit)
        // Most recent first — the last-registered tool leads.
        XCTAssertEqual(tools.first, MCPToolID.allCases.last)
    }

    // MARK: - Expiry

    func testSessionExpiresAfterStaleWindow() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0)

        let justInside = t0.addingTimeInterval(AgentSessionRegistry.staleAfter)
        XCTAssertEqual(registry.activeSessions(asOf: justInside).count, 1)

        let justOutside = t0.addingTimeInterval(AgentSessionRegistry.staleAfter + 1)
        XCTAssertTrue(registry.activeSessions(asOf: justOutside).isEmpty)
    }

    func testCallAfterExpiryStartsAFreshSession() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0)
        registry.recordKeepAwake(clientName: "c", at: t0)

        // Idle past the window, then reappear: connectedAt restarts and the
        // stale keep-awake attribution doesn't survive the gap.
        let later = t0.addingTimeInterval(AgentSessionRegistry.staleAfter + 60)
        registry.recordCall(clientName: "c", tool: .preflightCheck, at: later)

        let session = registry.activeSessions(asOf: later)[0]
        XCTAssertEqual(session.connectedAt, later)
        XCTAssertEqual(session.recentTools, [.preflightCheck])
        XCTAssertFalse(session.holdsKeepAwake)
    }

    // MARK: - Multi-session views

    func testOtherActiveSessionsExcludesCaller() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "Claude Code", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "Cursor", tool: .getSystemSnapshot, at: t0)

        let others = registry.otherActiveSessions(excluding: "Claude Code", asOf: t0)
        XCTAssertEqual(others.map(\.clientName), ["Cursor"])
    }

    func testActiveSessionsSortsMostRecentFirst() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "a", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "b", tool: .getSystemSnapshot, at: t0.addingTimeInterval(10))

        XCTAssertEqual(registry.activeSessions(asOf: t0.addingTimeInterval(10)).map(\.clientName), ["b", "a"])
    }

    // MARK: - Keep-awake attribution

    func testKeepAwakeIsSingleHolderAndMoves() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "a", tool: .keepAwake, at: t0)
        registry.recordKeepAwake(clientName: "a", at: t0)
        XCTAssertTrue(registry.activeSessions(asOf: t0).first { $0.clientName == "a" }!.holdsKeepAwake)

        // A second session's keep_awake replaces the (single) assertion, so
        // the flag moves rather than accumulates.
        registry.recordCall(clientName: "b", tool: .keepAwake, at: t0)
        registry.recordKeepAwake(clientName: "b", at: t0)
        let sessions = registry.activeSessions(asOf: t0)
        XCTAssertFalse(sessions.first { $0.clientName == "a" }!.holdsKeepAwake)
        XCTAssertTrue(sessions.first { $0.clientName == "b" }!.holdsKeepAwake)
    }

    func testClearKeepAwakeClearsEveryFlag() {
        let registry = AgentSessionRegistry()
        registry.recordKeepAwake(clientName: "a", at: t0)
        registry.clearKeepAwake()
        XCTAssertFalse(registry.activeSessions(asOf: t0).contains(where: \.holdsKeepAwake))
    }

    func testRecordKeepAwakeForUnknownClientRegistersIt() {
        // Defensive path: attribution shouldn't depend on recordCall having
        // run first, even though authorize guarantees it in practice.
        let registry = AgentSessionRegistry()
        registry.recordKeepAwake(clientName: "a", at: t0)
        let session = registry.activeSessions(asOf: t0)[0]
        XCTAssertEqual(session.clientName, "a")
        XCTAssertTrue(session.holdsKeepAwake)
        XCTAssertEqual(session.recentTools, [.keepAwake])
    }

    // MARK: - callCount

    /// Unlike `recentTools` (deduplicated, capped at 8), `callCount` is a raw
    /// total — the whole reason it exists is that `recentTools.count` cannot
    /// answer "how many calls happened," only "how many distinct recent tool
    /// names fit in the window."
    func testCallCountTalliesEveryCallIncludingRepeats() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0.addingTimeInterval(1))
        registry.recordCall(clientName: "c", tool: .preflightCheck, at: t0.addingTimeInterval(2))

        XCTAssertEqual(registry.activeSessions(asOf: t0.addingTimeInterval(2))[0].callCount, 3)
    }

    /// A fresh session after expiry restarts the tally — same "no continuity
    /// across the idle gap" rule `connectedAt` already follows.
    func testCallCountRestartsAfterSessionExpires() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0.addingTimeInterval(1))

        let later = t0.addingTimeInterval(AgentSessionRegistry.staleAfter + 60)
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: later)

        XCTAssertEqual(registry.activeSessions(asOf: later)[0].callCount, 1)
    }

    // MARK: - activitySummary(asOf:)

    /// The healthy common case: nobody's talked to this Mac, so the summary
    /// should say exactly that — zero calls, no last-activity time, no names
    /// — rather than `nil` (which is `SystemSnapshot`'s "not measured at all"
    /// state, a different claim entirely).
    func testActivitySummaryWithNoSessionsIsZeroNotNil() {
        let registry = AgentSessionRegistry()
        let summary = registry.activitySummary(asOf: t0)
        XCTAssertEqual(summary.toolCallCount, 0)
        XCTAssertNil(summary.lastActivityAt)
        XCTAssertEqual(summary.recentToolNames, [])
    }

    /// The whole point of this type: the summary must reflect *every* active
    /// session's activity, not just one — two agents talking to the Mac at
    /// once must both be counted.
    func testActivitySummaryAggregatesAcrossEverySession() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "Claude Code", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "Claude Code", tool: .getSystemSnapshot, at: t0.addingTimeInterval(1))
        registry.recordCall(clientName: "Cursor", tool: .preflightCheck, at: t0.addingTimeInterval(5))

        let summary = registry.activitySummary(asOf: t0.addingTimeInterval(5))
        XCTAssertEqual(summary.toolCallCount, 3)
        XCTAssertEqual(summary.lastActivityAt, t0.addingTimeInterval(5))
        XCTAssertTrue(summary.recentToolNames.contains(MCPToolID.getSystemSnapshot.rawValue))
        XCTAssertTrue(summary.recentToolNames.contains(MCPToolID.preflightCheck.rawValue))
    }

    /// `lastActivityAt` is the max across sessions, not the first or last
    /// session enumerated — an idle-but-still-active session must not shadow
    /// a more recently active one.
    func testActivitySummaryLastActivityAtIsTheMaxAcrossSessions() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "old", tool: .getSystemSnapshot, at: t0)
        registry.recordCall(clientName: "new", tool: .preflightCheck, at: t0.addingTimeInterval(120))

        let summary = registry.activitySummary(asOf: t0.addingTimeInterval(120))
        XCTAssertEqual(summary.lastActivityAt, t0.addingTimeInterval(120))
    }

    /// Sessions that expired before `asOf` must not contribute to the
    /// summary at all — same lazy-pruning behaviour `activeSessions` has.
    func testActivitySummaryExcludesExpiredSessions() {
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "c", tool: .getSystemSnapshot, at: t0)

        let later = t0.addingTimeInterval(AgentSessionRegistry.staleAfter + 1)
        let summary = registry.activitySummary(asOf: later)
        XCTAssertEqual(summary.toolCallCount, 0)
        XCTAssertNil(summary.lastActivityAt)
        XCTAssertEqual(summary.recentToolNames, [])
    }

    /// `recentToolNames` is capped the same way a single session's
    /// `recentTools` is — this rides the same size-constrained `WCSession`
    /// payload once it reaches the Watch.
    func testActivitySummaryRecentToolNamesIsCapped() {
        let registry = AgentSessionRegistry()
        for (index, tool) in MCPToolID.allCases.enumerated() {
            registry.recordCall(clientName: "c", tool: tool, at: t0.addingTimeInterval(Double(index)))
        }
        let summary = registry.activitySummary(asOf: t0.addingTimeInterval(Double(MCPToolID.allCases.count)))
        XCTAssertLessThanOrEqual(summary.recentToolNames.count, AgentSessionRegistry.recentToolsLimit)
    }
}
