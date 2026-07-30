import Foundation
import MacStatKit

/// Drives the Dashboard tab (plan §12.1). Owns the one `MockDataSource`
/// instance for this run and exposes just enough state — the device list,
/// which one is selected, and its latest snapshot — for `DashboardTabView`
/// to render the freshness banner and (eventually, from other agents'
/// work) the battery/sleep/metric cards.
///
/// **Why `any StatsTransport`, not `MockDataSource` concretely, for the
/// snapshot stream.** The device catalog access (`devices()`) is a
/// `MockDataSource`-only convenience — see that type's doc comment on why
/// it isn't part of the protocol — so this view model does need a concrete
/// reference for that one call. But the actual live data path
/// (`snapshots()`) is typed through `StatsTransport` deliberately: the day
/// a real `CloudKitTransport` exists, swapping `MockDataSource()` for
/// `CloudKitTransport()` at the call site that constructs this view model
/// is the entire migration for the snapshot-consuming half of this type.
/// Only the `init` needs to know the concrete mock type.
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var latestSnapshot: SystemSnapshot?

    private let transport: any StatsTransport
    private let dataSource: MockDataSource
    private var snapshotTask: Task<Void, Never>?

    /// Feeds every received snapshot into the App-Group-shared
    /// `WidgetSnapshot` cache `MacStatWidget` reads (plan §12.3). Owned here
    /// rather than constructed at the call site because it needs to see the
    /// exact same snapshot stream this view model already observes — a
    /// second, independent `StatsTransport` subscription would double the
    /// `MockDataSource` timer work for no benefit and risk the widget cache
    /// and the dashboard UI drifting out of sync with each other.
    private let widgetSnapshotWriter = WidgetSnapshotWriter()

    init(dataSource: MockDataSource = MockDataSource()) {
        self.dataSource = dataSource
        self.transport = dataSource
    }

    var selectedDevice: Device? {
        devices.first { $0.deviceID == selectedDeviceID } ?? devices.first
    }

    /// Loads the device catalog and starts observing the snapshot stream.
    /// Not called from `init` (matches `DashboardViewModel.refresh()`'s
    /// Mac-side convention of keeping construction cheap and side-effect
    /// free — see `MacStat/Dashboard/DashboardView.swift`'s `.task` call
    /// site) — the owning view calls this from `.task`, tied to actual
    /// on-screen appearance rather than object construction.
    func start() async {
        devices = await dataSource.devices()
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first?.deviceID
        }
        observeSnapshots()
    }

    private func observeSnapshots() {
        snapshotTask?.cancel()
        let transport = self.transport
        let writer = widgetSnapshotWriter
        snapshotTask = Task { [weak self] in
            for await snapshot in transport.snapshots() {
                guard !Task.isCancelled else { return }
                self?.latestSnapshot = snapshot
                // `selectedDevice` (not raw `devices.first`) so the cache
                // follows whichever Mac the dashboard is actually showing,
                // once a device picker exists for more than one Mac.
                if let device = self?.selectedDevice {
                    await writer.record(device: device, snapshot: snapshot)
                }
            }
        }
    }

    deinit {
        snapshotTask?.cancel()
    }
}
