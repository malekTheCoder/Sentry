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
}
