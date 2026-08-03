import Combine
import Foundation
import SentryKit

/// Drives the Dashboard tab (plan §12.1). Reads from the app-wide
/// `AppDataSource.shared` (`SentryMobile/Data/AppDataSource.swift`) rather
/// than owning its own transport — see that type's doc comment for why:
/// this view model used to construct its own `MockDataSource()` via a
/// default parameter, which was harmless for a stateless mock but would be
/// wrong for a real network transport (one Bonjour browser/socket per view
/// model instead of one for the whole app). `devices()`
/// exposes just enough state — the device list, which one is selected, and
/// its latest snapshot — for `DashboardTabView` to render the freshness
/// banner and (eventually, from other agents' work) the battery/sleep/metric
/// cards.
///
/// **Why `any StatsTransport`, not a concrete type, for the snapshot
/// stream.** `AppDataSource.transport` is itself typed `any StatsTransport`
/// and can change identity at runtime (mock → `LocalSyncClient` once
/// discovery finishes, see `AppDataSource.resolveIfNeeded()`) — this view
/// model resubscribes to `appDataSource.$transport` (see `observeSnapshots
/// (transport:)` below) specifically to follow that switch rather than
/// staying latched onto whichever transport happened to be current when
/// `start()` was first called. The device catalog access (`devices()`) is a
/// `MockDataSource`-only convenience even after this generalization — see
/// `AppDataSource.devices()`'s doc comment for how it's synthesized for the
/// local-sync case instead.
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var latestSnapshot: SystemSnapshot?

    /// Rolling ~60-sample window per headline metric, appended as snapshots
    /// arrive — the data behind the ledger sparklines and the Activity
    /// chart the redesign handoff calls for. In-memory only (the phone has
    /// no history store); it starts empty and honestly shows nothing until
    /// samples accumulate.
    @Published private(set) var recentSeries: [MetricID: [Double]] = [:]

    /// One minute of samples at the Mac's default cadence; enough for the
    /// handoff's "60 s" window, small enough to never matter memory-wise.
    private static let seriesCap = 60

    private let appDataSource: AppDataSource
    private var snapshotTask: Task<Void, Never>?
    private var transportSubscription: AnyCancellable?

    /// Feeds every received snapshot into the App-Group-shared
    /// `WidgetSnapshot` cache `SentryWidget` reads (plan §12.3). Owned here
    /// rather than constructed at the call site because it needs to see the
    /// exact same snapshot stream this view model already observes — a
    /// second, independent `StatsTransport` subscription would double the
    /// underlying transport's work for no benefit and risk the widget cache
    /// and the dashboard UI drifting out of sync with each other.
    private let widgetSnapshotWriter = WidgetSnapshotWriter()

    init(appDataSource: AppDataSource = .shared) {
        self.appDataSource = appDataSource
    }

    var selectedDevice: Device? {
        devices.first { $0.deviceID == selectedDeviceID } ?? devices.first
    }

    /// Loads the device catalog and starts observing the snapshot stream.
    /// Not called from `init` (matches `DashboardViewModel.refresh()`'s
    /// Mac-side convention of keeping construction cheap and side-effect
    /// free — see `Sentry/Dashboard/DashboardView.swift`'s `.task` call
    /// site) — the owning view calls this from `.task`, tied to actual
    /// on-screen appearance rather than object construction.
    func start() async {
        devices = await appDataSource.devices()
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first?.deviceID
        }
        // Follow `appDataSource.transport` for the lifetime of this view
        // model, not just its value at `start()` time — local-sync
        // discovery (`AppDataSource.resolveIfNeeded()`) can finish shortly
        // after this method already began observing the placeholder mock.
        transportSubscription = appDataSource.$transport
            .sink { [weak self] transport in
                guard let self else { return }
                Task { [weak self] in
                    self?.devices = await self?.appDataSource.devices() ?? []
                }
                self.observeSnapshots(transport: transport)
            }
    }

    private func observeSnapshots(transport: any StatsTransport) {
        snapshotTask?.cancel()
        let writer = widgetSnapshotWriter
        // Same derivation `WatchRelayManager.consider(_:)` uses for the
        // Watch payload's honesty flag: the transport identity, not the
        // data, is what distinguishes demo from real (`MockDataSource`'s
        // output is plausible-looking by design).
        let sourceIsDemoData = transport is MockDataSource
        snapshotTask = Task { [weak self] in
            for await snapshot in transport.snapshots() {
                guard !Task.isCancelled else { return }
                self?.latestSnapshot = snapshot
                self?.appendToSeries(snapshot)
                // `selectedDevice` (not raw `devices.first`) so the cache
                // follows whichever Mac the dashboard is actually showing,
                // once a device picker exists for more than one Mac.
                if let device = self?.selectedDevice {
                    await writer.record(device: device, snapshot: snapshot, sourceIsDemoData: sourceIsDemoData)
                }
            }
        }
    }

    /// Only values that actually exist get appended — a snapshot missing a
    /// module contributes nothing to that series rather than a fake zero,
    /// so a sparkline never draws a dip that didn't happen.
    private func appendToSeries(_ snapshot: SystemSnapshot) {
        var updated = recentSeries
        func append(_ metric: MetricID, _ value: Double?) {
            guard let value else { return }
            var values = updated[metric] ?? []
            values.append(value)
            if values.count > Self.seriesCap {
                values.removeFirst(values.count - Self.seriesCap)
            }
            updated[metric] = values
        }
        append(.cpuTotalPercent, snapshot.cpu?.totalPercent)
        append(.gpuUtilizationPercent, snapshot.gpu?.utilizationPercent)
        if let memory = snapshot.memory, memory.totalBytes > 0 {
            append(.memoryUsedBytes, Double(memory.usedBytes) / Double(memory.totalBytes) * 100)
        }
        append(.networkRxBytesPerSec, snapshot.network?.rxBytesPerSec)
        recentSeries = updated
    }

    deinit {
        snapshotTask?.cancel()
    }
}
