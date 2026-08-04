import XCTest
@testable import Sentry
@testable import SentryKit

/// Covers the gap this branch closes: `set_refresh_interval` (plan §13.4,
/// `MCPXPCService.setRefreshInterval`) could only retune the `.fast`/
/// `.medium`/`.slow` tiers, leaving the `.process` tier (backing
/// `SystemSnapshot.topProcesses` and process-scoped alert responsiveness —
/// see `StatsCoordinator.Tier`'s doc comment) unreachable over MCP/XPC.
///
/// Exercises the real `MCPXPCService.setRefreshInterval` dispatch switch
/// end-to-end (real `StatsCoordinator`, `SettingsStore`, `HistoryStore`,
/// `AlertEngine`, `PowerControlService`, `MCPAccessController`,
/// `MCPActivityLog` — all constructed with test-friendly, in-memory/temp-file
/// defaults) rather than re-deriving the dispatch logic in a test double, so
/// a future edit to that switch statement is caught here, not just at the
/// `StatsCoordinator.setProcessInterval` unit-test level.
@MainActor
final class SetRefreshIntervalProcessTierTests: XCTestCase {

    private func makeService() -> (MCPXPCService, StatsCoordinator, SettingsStore) {
        let coordinator = StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { nil },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil }
        )
        let historyStore = HistoryStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SetRefreshIntervalProcessTierTests-\(UUID().uuidString).sqlite"))
        let alertEngine = AlertEngine(rules: [], historyStore: historyStore)
        let powerControl = PowerControlService(defaults: UserDefaults(suiteName: "SetRefreshIntervalProcessTierTests-\(UUID().uuidString)")!)
        let settingsStore = SettingsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("SetRefreshIntervalProcessTierTests-\(UUID().uuidString).json")
        )
        // Enable the MCP server and this specific write tool — mirrors what
        // a user checking the "Set Refresh Interval" toggle in AIAccessPane
        // does. Leaving `mcpConfirmationRequiredToolIDs` empty (the default)
        // avoids driving `presentConfirmationAlert`'s real `NSAlert.runModal()`.
        settingsStore.settings.mcpServerEnabled = true
        settingsStore.settings.mcpWriteToolsEnabled = true
        settingsStore.settings.mcpEnabledToolIDs.insert(MCPToolID.setRefreshInterval.rawValue)

        let service = MCPXPCService(
            coordinator: coordinator,
            historyStore: historyStore,
            alertEngine: alertEngine,
            powerControl: powerControl,
            settingsStore: settingsStore,
            accessController: MCPAccessController(),
            activityLog: MCPActivityLog()
        )
        return (service, coordinator, settingsStore)
    }

    private func setRefreshInterval(_ service: MCPXPCService, tier: String, seconds: Double) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            service.setRefreshInterval(clientName: "test-client", tier: tier, seconds: seconds) { success, message in
                continuation.resume(returning: (success, message))
            }
        }
    }

    func testProcessTierDispatchesToCoordinatorSetProcessInterval() async {
        let (service, coordinator, _) = makeService()

        let (success, message) = await setRefreshInterval(service, tier: "process", seconds: 12)

        XCTAssertTrue(success)
        XCTAssertNil(message)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .process), 12)
    }

    func testProcessTierGoesThroughCoordinatorDirectlyNotSettingsStore() async {
        // Unlike fast/medium/slow, there is no `AppSettings` field backing
        // this tier (see `StatsCoordinator.processInterval`'s doc comment) —
        // pin that the coordinator's live value changed even though nothing
        // in `AppSettings` could possibly have been mutated to cause it.
        let (service, coordinator, settingsStore) = makeService()
        let settingsBefore = settingsStore.settings

        _ = await setRefreshInterval(service, tier: "process", seconds: 15)

        XCTAssertEqual(coordinator.currentBaseInterval(for: .process), 15)
        XCTAssertEqual(settingsStore.settings, settingsBefore, "no AppSettings field exists for the process tier yet")
    }

    func testProcessTierValueIsClampedTheSameWayCoordinatorClamps() async {
        let (service, coordinator, _) = makeService()

        _ = await setRefreshInterval(service, tier: "process", seconds: 0.1)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .process), 2)

        _ = await setRefreshInterval(service, tier: "process", seconds: 9999)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .process), 60)
    }

    func testUnrecognizedTierIsDeniedTheSameHonestWayAsBefore() async {
        // Matches the existing fast/medium/slow behavior exactly: an
        // unrecognized tier string never silently no-ops — it replies
        // `false` with an explanatory message naming every valid tier,
        // `"process"` included now.
        let (service, coordinator, _) = makeService()
        let baseline = coordinator.currentBaseInterval(for: .process)

        let (success, message) = await setRefreshInterval(service, tier: "bogus", seconds: 10)

        XCTAssertFalse(success)
        XCTAssertEqual(message, "Unknown tier 'bogus'. Expected one of: fast, medium, slow, process.")
        XCTAssertEqual(coordinator.currentBaseInterval(for: .process), baseline, "a rejected tier must not mutate any tier's interval")
    }

    func testFastMediumSlowTiersStillGoThroughSettingsStore() async {
        // Regression guard: adding the `.process` case must not disturb the
        // pre-existing three cases' settings-backed dispatch.
        let (service, _, settingsStore) = makeService()

        _ = await setRefreshInterval(service, tier: "fast", seconds: 4)
        _ = await setRefreshInterval(service, tier: "medium", seconds: 9)
        _ = await setRefreshInterval(service, tier: "slow", seconds: 40)

        XCTAssertEqual(settingsStore.settings.globalRefreshInterval, 4)
        XCTAssertEqual(settingsStore.settings.mediumTierRefreshInterval, 9)
        XCTAssertEqual(settingsStore.settings.slowTierRefreshInterval, 40)
    }
}
