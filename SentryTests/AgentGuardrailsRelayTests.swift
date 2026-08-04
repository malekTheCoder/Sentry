import XCTest
@testable import SentryKit

/// Covers the additive `SystemSnapshot`/`StatsCoordinator` seam this branch
/// adds for the Watch resume feature and the new Siri intents:
/// `agentAccessPaused` (mirroring `AppSettings.agentGuardrails
/// .killSwitchEngaged`) and `protectionScore`. Both are wired end-to-end but
/// deliberately never assigned by this branch — see
/// `StatsCoordinator.agentAccessPaused`'s and `.protectionScore`'s doc
/// comments for the one-line composition-root hooks still outstanding in
/// `Sentry/App/AppDelegate.swift`, which this branch does not touch. What
/// *is* testable without that hook: the properties round-trip through
/// `buildSnapshot()` once assigned, and default to `nil` (never a fabricated
/// `false`/`0`) when nothing has assigned them.
@MainActor
final class AgentGuardrailsRelayTests: XCTestCase {

    private func makeCoordinator() -> StatsCoordinator {
        StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { nil },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil }
        )
    }

    func testAgentAccessPausedDefaultsToNilNotFalse() {
        let coordinator = makeCoordinator()
        XCTAssertNil(coordinator.agentAccessPaused)
        XCTAssertNil(coordinator.latestSnapshot().agentAccessPaused)
    }

    func testProtectionScoreDefaultsToNilNotZero() {
        let coordinator = makeCoordinator()
        XCTAssertNil(coordinator.protectionScore)
        XCTAssertNil(coordinator.latestSnapshot().protectionScore)
    }

    func testAssigningAgentAccessPausedFlowsThroughToTheBuiltSnapshot() {
        let coordinator = makeCoordinator()
        coordinator.agentAccessPaused = true
        XCTAssertEqual(coordinator.latestSnapshot().agentAccessPaused, true)

        coordinator.agentAccessPaused = false
        XCTAssertEqual(coordinator.latestSnapshot().agentAccessPaused, false)
    }

    func testAssigningProtectionScoreFlowsThroughToTheBuiltSnapshot() {
        let coordinator = makeCoordinator()
        coordinator.protectionScore = 87
        XCTAssertEqual(coordinator.latestSnapshot().protectionScore, 87)
    }

    /// `SystemSnapshot`'s own memberwise `init` — the same "new fields
    /// default to nil so every existing call site keeps compiling and
    /// keeps meaning what it meant" convention `WatchRelaySnapshot`
    /// documents at length.
    func testSystemSnapshotInitDefaultsBothNewFieldsToNil() {
        let snapshot = SystemSnapshot(deviceID: "test-device")
        XCTAssertNil(snapshot.agentAccessPaused)
        XCTAssertNil(snapshot.protectionScore)
    }

    func testSystemSnapshotInitAcceptsBothNewFieldsExplicitly() {
        let snapshot = SystemSnapshot(
            deviceID: "test-device",
            agentAccessPaused: true,
            protectionScore: 42
        )
        XCTAssertEqual(snapshot.agentAccessPaused, true)
        XCTAssertEqual(snapshot.protectionScore, 42)
    }
}
