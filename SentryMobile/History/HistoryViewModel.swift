import Combine
import Foundation
import SentryKit

/// Drives the History tab (plan §12.1). Reads from the app-wide
/// `AppDataSource.shared` (`SentryMobile/Data/AppDataSource.swift`), the
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

    /// The window `dailyHealth` was last fetched for, for the chart to pin its
    /// x-axis to — see `BatteryHealthTrendChart.window`.
    ///
    /// Captured here, at fetch time, rather than derived in the view from
    /// `selectedRange.since(Date())`: a view recomputes on every body evaluation
    /// and would slide the axis a few milliseconds each time, which is both
    /// pointless churn and a domain that no longer matches the rows drawn on it.
    ///
    /// `nil` for `.all`, which resolves to `.distantPast` (see `HistoryRange
    /// .since(now:)`) — a two-thousand-year domain would compress every real day
    /// into a sub-pixel sliver at the right edge. "All history" has no requested
    /// left edge to fall short of, so the auto-fitted domain is the honest one,
    /// exactly as on the Mac's all-time battery cards.
    @Published private(set) var window: ClosedRange<Date>?

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
        let now = Date()
        let since = selectedRange.since(now: now)
        window = since > .distantPast ? since...now : nil
        dailyHealth = await appDataSource.dailyHealthHistory(
            deviceID: device.deviceID,
            dayCount: selectedRange.syntheticDayCount
        )
    }

    /// How much of the selected window the fetched series actually covers — the
    /// caption under the range selector, and the reason the chart's short trace
    /// carries a number rather than only a shape. See
    /// `SentryKit/History/HistoryCoverage.swift`.
    ///
    /// `resolution: 86400` because `DailyHealth` is one record per day, stamped
    /// at midnight: without that floor the newest record would look like up to
    /// 24h of missing tail on every single chart, which on a 7-day window is 14%
    /// of the range and would make the honest signal fire permanently and mean
    /// nothing.
    var coverage: HistoryCoverage {
        HistoryCoverage(
            requested: window,
            timestamps: dailyHealth.map(\.day),
            resolution: 86400
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
