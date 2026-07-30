import Combine
import Foundation
import MacStatKit

/// Drives the History tab (plan §12.1). Reads from the app-wide
/// `AppDataSource.shared` (`MacStatMobile/Data/AppDataSource.swift`), the
/// same shared instance `DashboardViewModel` reads from — previously this
/// type owned its own independent `MockDataSource()`, which was harmless
/// duplication for a stateless mock (two instances both reporting the same
/// constant `mockDevice`) but would mean a second, redundant Bonjour
/// browser/socket once a real `LocalSyncClient` is behind
/// `AppDataSource.transport`. See `AppDataSource`'s doc comment for the full
/// reasoning behind the shared-instance change.
///
/// **Why `any StatsTransport`, not a concrete type, for the snapshot
/// stream.** Same reasoning as `DashboardViewModel`'s identical split:
/// `dailyHealthHistory(deviceID:dayCount:)` is a `MockDataSource`-only
/// convenience generalized onto `AppDataSource` (see its doc comment), not
/// part of `StatsTransport` itself. The live snapshot path (`snapshots()`,
/// used only for the per-metric browser's current values) follows
/// `appDataSource.$transport` so a local-sync connection that finishes
/// resolving after `start()` was already called is still picked up.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var device: Device?
    @Published private(set) var dailyHealth: [DailyHealth] = []
    @Published private(set) var latestSnapshot: SystemSnapshot?
    @Published var selectedRange: HistoryRange = .last30Days

    private let appDataSource: AppDataSource
    private var snapshotTask: Task<Void, Never>?
    private var transportSubscription: AnyCancellable?

    init(appDataSource: AppDataSource = .shared) {
        self.appDataSource = appDataSource
    }

    /// Loads the device + first `DailyHealth` series and starts observing
    /// snapshots. Called from the view's `.task`, not `init`, matching
    /// `DashboardViewModel.start()`'s convention of keeping construction
    /// cheap and side-effect free.
    func start() async {
        let devices = await appDataSource.devices()
        device = devices.first
        await reloadDailyHealth()
        transportSubscription = appDataSource.$transport
            .sink { [weak self] transport in
                self?.observeSnapshots(transport: transport)
            }
    }

    /// Re-fetches the `DailyHealth` series at the currently selected range's
    /// day count. Called from the range selector's `.onChange` in
    /// `HistoryTabView`. Delegates to `AppDataSource.dailyHealthHistory
    /// (deviceID:dayCount:)`, which returns real synthetic data for the mock
    /// transport and an honestly-empty array for the local-sync transport
    /// (see that method's doc comment — this wire protocol doesn't carry
    /// health history yet).
    func reloadDailyHealth() async {
        guard let device else { return }
        dailyHealth = await appDataSource.dailyHealthHistory(
            deviceID: device.deviceID,
            dayCount: selectedRange.syntheticDayCount
        )
    }

    private func observeSnapshots(transport: any StatsTransport) {
        snapshotTask?.cancel()
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
