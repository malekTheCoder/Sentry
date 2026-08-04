import XCTest
@testable import SentryKit

/// Covers `AgentActivitySummary` (`SentryKit/Models/SystemSnapshot.swift`) and
/// `SystemSnapshot.agentActivitySummary`'s honest-nil convention — the same
/// convention `agentAccessPaused`/`protectionScore` already establish on that
/// type, applied to the new field this branch adds.
final class AgentActivitySummaryTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Encode/decode round trip

    /// `AgentActivitySummary` rides inside `SystemSnapshot`, which crosses
    /// process boundaries (CloudKit, the Mac->iPhone local-sync transport) as
    /// JSON — so a summary that doesn't survive a plain encode/decode round
    /// trip would silently corrupt every consumer downstream of that boundary.
    func testRoundTripsThroughJSONExactly() throws {
        let original = AgentActivitySummary(
            toolCallCount: 7,
            lastActivityAt: reference,
            recentToolNames: ["get_stats", "keep_awake", "get_agent_activity"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentActivitySummary.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    /// `lastActivityAt` is `nil` when there is real data (a zero-call summary)
    /// — this must round-trip as an absent key, not a fabricated date.
    func testNilLastActivityAtRoundTripsAsNilNotAsAFabricatedDate() throws {
        let original = AgentActivitySummary(toolCallCount: 0, lastActivityAt: nil, recentToolNames: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentActivitySummary.self, from: data)
        XCTAssertNil(decoded.lastActivityAt)
        XCTAssertEqual(decoded.toolCallCount, 0)
        XCTAssertEqual(decoded.recentToolNames, [])
    }

    // MARK: SystemSnapshot's honest-nil convention

    /// `SystemSnapshot.agentActivitySummary` defaults to `nil` — "not measured
    /// this run," the same convention `agentAccessPaused`/`protectionScore`
    /// establish on the same type — never a fabricated zero-valued summary.
    func testSystemSnapshotDefaultsAgentActivitySummaryToNil() {
        let snapshot = SystemSnapshot(deviceID: "test-device")
        XCTAssertNil(snapshot.agentActivitySummary)
    }

    /// A `SystemSnapshot` that does carry a summary must preserve it exactly
    /// through the same JSON boundary `SystemSnapshot` itself crosses.
    func testSystemSnapshotRoundTripsANonNilAgentActivitySummary() throws {
        let summary = AgentActivitySummary(
            toolCallCount: 3,
            lastActivityAt: reference,
            recentToolNames: ["get_stats"]
        )
        let original = SystemSnapshot(deviceID: "test-device", agentActivitySummary: summary)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SystemSnapshot.self, from: data)
        XCTAssertEqual(decoded.agentActivitySummary, summary)
    }

    /// A `SystemSnapshot` predating this field (no `agentActivitySummary` key
    /// at all) must decode with the field `nil`, not throw — the same
    /// additive-tolerant contract every other Optional field on this type
    /// already gets from synthesized `Codable`.
    func testSystemSnapshotMissingTheKeyEntirelyDecodesWithNilSummary() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "timestamp": \(reference.timeIntervalSinceReferenceDate),
          "deviceID": "legacy-device",
          "schemaVersion": 1
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(SystemSnapshot.self, from: data)
        XCTAssertNil(decoded.agentActivitySummary)
    }
}
