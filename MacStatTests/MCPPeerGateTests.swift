import XCTest
@testable import MacStatKit

/// Drives every branch of `MCPPeerGate.decide` with a fake evaluator —
/// the split `FanDaemonPeerGateTests` established, applied to the app-side
/// gate. The requirement text is pinned verbatim for the production team
/// so a change to the identifiers or the anatomy fails a test that names
/// what must be kept in sync.
final class MCPPeerGateTests: XCTestCase {

    private struct StubEvaluator: FanDaemonPeerEvaluator {
        var failure: FanDaemonPeerFailure?
        var observedRequirement: ((String) -> Void)?
        func evaluate(pid: Int32, requirement: String) -> FanDaemonPeerFailure? {
            observedRequirement?(requirement)
            return failure
        }
    }

    // MARK: - Requirement text

    /// Pinned against the production team (`DEVELOPMENT_TEAM` in the
    /// `DeveloperIDSigned` template in project.yml) — the exact string a
    /// Developer ID build evaluates, since the host's own team IS that
    /// team there. The two identifiers are the CLI's and MCP binary's
    /// bundle ids from the same file.
    func testRequirementTextForProductionTeam() {
        XCTAssertEqual(
            MCPPeerGate.requirement(teamID: "H7T2D2GL7U"),
            "(identifier \"dev.malekswilam.macstat.cli\" or identifier \"dev.malekswilam.macstat.mcp\") and anchor apple generic and certificate leaf[subject.OU] = \"H7T2D2GL7U\""
        )
    }

    // MARK: - Fail-closed branches

    func testRejectsImplausiblePids() {
        let evaluator = StubEvaluator(failure: nil)
        XCTAssertEqual(MCPPeerGate.decide(pid: 0, ownPID: 100, teamID: "T", evaluator: evaluator),
                       .reject(.implausiblePeer(pid: 0)))
        XCTAssertEqual(MCPPeerGate.decide(pid: 1, ownPID: 100, teamID: "T", evaluator: evaluator),
                       .reject(.implausiblePeer(pid: 1)))
        XCTAssertEqual(MCPPeerGate.decide(pid: -5, ownPID: 100, teamID: "T", evaluator: evaluator),
                       .reject(.implausiblePeer(pid: -5)))
        XCTAssertEqual(MCPPeerGate.decide(pid: 100, ownPID: 100, teamID: "T", evaluator: evaluator),
                       .reject(.implausiblePeer(pid: 100)))
    }

    /// No team — ad-hoc host — refuses everyone, before the evaluator is
    /// ever consulted. An empty string is not a team either.
    func testRejectsWhenHostUnsigned() {
        var evaluatorRan = false
        let evaluator = StubEvaluator(failure: nil, observedRequirement: { _ in evaluatorRan = true })
        XCTAssertEqual(MCPPeerGate.decide(pid: 500, ownPID: 100, teamID: nil, evaluator: evaluator),
                       .reject(.hostUnsigned))
        XCTAssertEqual(MCPPeerGate.decide(pid: 500, ownPID: 100, teamID: "", evaluator: evaluator),
                       .reject(.hostUnsigned))
        XCTAssertFalse(evaluatorRan)
    }

    func testEvaluatorFailuresMapOneToOne() {
        func decision(_ failure: FanDaemonPeerFailure) -> MCPPeerDecision {
            MCPPeerGate.decide(pid: 500, ownPID: 100, teamID: "T", evaluator: StubEvaluator(failure: failure))
        }
        XCTAssertEqual(decision(.staticCodeUnavailable(osStatus: -1)),
                       .reject(.staticCodeUnavailable(osStatus: -1)))
        XCTAssertEqual(decision(.requirementNotSatisfied(osStatus: -2)),
                       .reject(.requirementNotSatisfied(osStatus: -2)))
        XCTAssertEqual(decision(.requirementMalformed(osStatus: -3)),
                       .reject(.requirementMalformed(osStatus: -3)))
        XCTAssertEqual(decision(.implausiblePeer(pid: 7)),
                       .reject(.implausiblePeer(pid: 7)))
    }

    // MARK: - The accept branch

    func testAcceptsOnlyWhenEvaluatorAffirms() {
        var seenRequirement: String?
        let evaluator = StubEvaluator(failure: nil, observedRequirement: { seenRequirement = $0 })
        let decision = MCPPeerGate.decide(pid: 500, ownPID: 100, teamID: "ABC123", evaluator: evaluator)
        XCTAssertEqual(decision, .accept)
        XCTAssertTrue(decision.isAccepted)
        // The requirement evaluated is the one built for the host's team —
        // not a constant that could silently diverge from it.
        XCTAssertEqual(seenRequirement, MCPPeerGate.requirement(teamID: "ABC123"))
    }

    func testEveryFailureHasPlainLanguageCopy() {
        let failures: [MCPPeerFailure] = [
            .implausiblePeer(pid: 3),
            .hostUnsigned,
            .staticCodeUnavailable(osStatus: -1),
            .requirementNotSatisfied(osStatus: -2),
            .requirementMalformed(osStatus: -3),
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty)
        }
    }
}
