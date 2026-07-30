import Foundation
import MacStatKit

/// Drives the History tab (plan §12.1). Owns its own `MockDataSource`
/// instance and its own snapshot subscription, deliberately not shared with
/// `DashboardViewModel` (`MacStatMobile/Dashboard/DashboardViewModel.swift`,
/// separate, concurrently-built file) — the plan doesn't specify cross-tab
/// state sharing, and two independent `MockDataSource()` instances each
/// reporting the same one `mockDevice` is harmless: `deviceID` is a stable
/// constant, not randomized per instance (see that type's doc comment).
///
/// **Why `any StatsTransport`, not `MockDataSource` concretely, for the
/// snapshot stream.** Same reasoning as `DashboardViewModel`'s identical
/// split: `dailyHealthHistory(deviceID:dayCount:)` is a `MockDataSource`-only
/// convenience (see its doc comment on why it isn't part of the protocol),
/// so this type needs a concrete reference for that one call. The live
/// snapshot path (`snapshots()`, used only for the per-metric browser's
/// current values) stays typed through `StatsTransport` so swapping in a
/// real `CloudKitTransport` later only changes `init`'s default argument.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var device: Device?
    @Published private(set) var dailyHealth: [DailyHealth] = []
    @Published private(set) var latestSnapshot: SystemSnapshot?
    @Published var selectedRange: HistoryRange = .last30Days

    private let dataSource: MockDataSource
    private let transport: any StatsTransport
    private var snapshotTask: Task<Void, Never>?

    init(dataSource: MockDataSource = MockDataSource()) {
        self.dataSource = dataSource
        self.transport = dataSource
    }

    /// Loads the device + first `DailyHealth` series and starts observing
    /// snapshots. Called from the view's `.task`, not `init`, matching
    /// `DashboardViewModel.start()`'s convention of keeping construction
    /// cheap and side-effect free.
    func start() async {
        let devices = await dataSource.devices()
        device = devices.first
        await reloadDailyHealth()
        observeSnapshots()
    }

    /// Re-fetches the synthetic `DailyHealth` series at the currently
    /// selected range's day count. Called from the range selector's
    /// `.onChange` in `HistoryTabView`. A real `DailyHealth` CloudKit query
    /// would instead vary its date predicate against `selectedRange.since(now:)`;
    /// this mock instead varies how many fabricated days it generates —
    /// see `HistoryRange.syntheticDayCount`'s doc comment.
    func reloadDailyHealth() async {
        guard let device else { return }
        dailyHealth = await dataSource.dailyHealthHistory(
            deviceID: device.deviceID,
            dayCount: selectedRange.syntheticDayCount
        )
    }

    private func observeSnapshots() {
        snapshotTask?.cancel()
        let transport = self.transport
        snapshotTask = Task { [weak self] in
            for await snapshot in transport.snapshots() {
                guard !Task.isCancelled else { return }
                self?.latestSnapshot = snapshot
            }
        }
    }

    deinit {
        snapshotTask?.cancel()
    }
}
