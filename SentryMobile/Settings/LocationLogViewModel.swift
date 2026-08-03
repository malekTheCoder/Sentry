import Combine
import Foundation
import SentryKit

// MARK: - LocationLogViewModel: drives the Settings tab's Location Log section

/// Follows `AppDataSource.shared`'s snapshot stream the same way
/// `DashboardViewModel` does (see that type's doc comment for the full
/// reasoning on why this reads from the shared `AppDataSource` rather than
/// owning its own transport, and why it resubscribes to `$transport` instead
/// of latching onto whichever transport was current at `start()` time) and
/// keeps just the one thing `LocationLogSection` needs: the most recent
/// `MacLocation` any snapshot has carried.
///
/// **Why this holds its own `lastLocation` rather than reading
/// `latestSnapshot?.location` off `DashboardViewModel` directly.** Not every
/// `SystemSnapshot` carries a location — `StatsCoordinator.location` only
/// changes when `LocationService` captures a fresh fix (every 15–30 minutes
/// on the Mac), so most snapshots broadcast a `nil` on this field even while
/// a real location was captured minutes ago and is still the honest "last
/// known" answer (`StatsCoordinator.buildSnapshot()`'s doc comment covers
/// the persist-until-replaced contract this relies on: once a fix lands, the
/// Mac's own coordinator keeps re-including it in every snapshot the sender
/// broadcasts until a newer one replaces it or the Mac restarts). This view
/// model has no reason to remember "the last snapshot," only "the last
/// snapshot that actually carried a location" — a plain `if let` guard, not
/// a stateful merge.
@MainActor
final class LocationLogViewModel: ObservableObject {
    @Published private(set) var lastLocation: MacLocation?

    private let appDataSource: AppDataSource
    private var snapshotTask: Task<Void, Never>?
    private var transportSubscription: AnyCancellable?

    init(appDataSource: AppDataSource = .shared) {
        self.appDataSource = appDataSource
    }

    /// Matches `DashboardViewModel.start()`'s convention: called from the
    /// owning view's `.task`, not from `init`, so constructing this object
    /// stays cheap and side-effect free.
    func start() {
        transportSubscription = appDataSource.$transport
            .sink { [weak self] transport in
                self?.observeSnapshots(transport: transport)
            }
    }

    private func observeSnapshots(transport: any StatsTransport) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            for await snapshot in transport.snapshots() {
                guard !Task.isCancelled else { return }
                if let location = snapshot.location {
                    self?.lastLocation = location
                }
            }
        }
    }

    deinit {
        snapshotTask?.cancel()
    }
}
