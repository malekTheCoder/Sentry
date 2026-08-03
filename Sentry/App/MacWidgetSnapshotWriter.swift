import Foundation
import SentryKit
import WidgetKit

// MARK: - MacWidgetSnapshotWriter: the Mac app's half of the desktop widget cache

/// The macOS counterpart of `SentryMobile`'s `WidgetSnapshotWriter`: projects
/// each live `SystemSnapshot` into the small `WidgetSnapshot` cache the
/// `SentryWidgetExtension_macOS` desktop widget reads, via the same
/// `WidgetSnapshotStore` App Group boundary.
///
/// **Why `sourceIsDemoData: false` here when the phone writer hardcodes
/// `true`.** The phone renders whatever a transport hands it, and today that
/// transport is `MockDataSource` — so its cache honestly discloses demo data.
/// This writer sits directly on `StatsCoordinator`'s stream of readings taken
/// on *this* machine by `SystemMetricsKit` collectors; there is no mock in
/// the path, so the disclosure would itself be the lie.
///
/// **Why `WidgetCenter` reloads are throttled but writes are not.** The store
/// write is a single `UserDefaults` set — cheap, and keeping the cache
/// current costs nothing. `reloadAllTimelines()` is not cheap: WidgetKit
/// budgets reloads per day, and a menu bar app ticking every few seconds
/// would burn that budget before lunch. The widget already re-polls the
/// store on the cadence `WidgetTimelineScheduler` decided, so the eager
/// reload only exists to make *visible* state changes (charging plugged/
/// unplugged, sleep assertion toggled) land promptly rather than at the next
/// scheduled reload.
actor MacWidgetSnapshotWriter {

    private var history: [WidgetBatteryHistoryPoint] = []
    private var lastReload: Date = .distantPast
    private var lastChargeState: (isCharging: Bool, isPluggedIn: Bool)?
    private var lastAssertionActive = false

    /// Floor between routine `WidgetCenter` reloads. Chosen to match
    /// `WidgetTimelineScheduler.wakingCadence`'s order of magnitude rather
    /// than the snapshot tick's.
    private static let reloadInterval: TimeInterval = 300

    private let deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// Call once per `SystemSnapshot` the coordinator publishes. Mirrors the
    /// phone writer's lossy, display-shaped projection — missing sub-structs
    /// degrade to `0`/`false`/`.inactive` for display only.
    func record(_ snapshot: SystemSnapshot) {
        let batteryPercent = snapshot.battery?.chargePercent ?? 0
        history = WidgetBatteryHistory.appending(
            WidgetBatteryHistoryPoint(date: snapshot.timestamp, percent: batteryPercent),
            to: history
        )

        let totalBytes = snapshot.memory?.totalBytes ?? 0
        let usedFraction: Double
        if totalBytes > 0, let usedBytes = snapshot.memory?.usedBytes {
            usedFraction = Double(usedBytes) / Double(totalBytes)
        } else {
            usedFraction = 0
        }

        let assertionActive: Bool
        if case .active = snapshot.sleepAssertion ?? .inactive {
            assertionActive = true
        } else {
            assertionActive = false
        }

        WidgetSnapshotStore.write(WidgetSnapshot(
            deviceName: deviceName,
            lastSeen: snapshot.timestamp,
            writtenAt: Date(),
            sourceIsDemoData: false,
            batteryPercent: batteryPercent,
            isCharging: snapshot.battery?.isCharging ?? false,
            isPluggedIn: snapshot.battery?.isPluggedIn ?? false,
            chargingWatts: snapshot.battery?.chargingWatts,
            cpuPercent: snapshot.cpu?.totalPercent ?? 0,
            memoryUsedFraction: usedFraction,
            sleepAssertion: snapshot.sleepAssertion ?? .inactive,
            batteryHistory: history
        ))

        reloadIfWarranted(snapshot: snapshot, assertionActive: assertionActive)
    }

    private func reloadIfWarranted(snapshot: SystemSnapshot, assertionActive: Bool) {
        let charge = (
            isCharging: snapshot.battery?.isCharging ?? false,
            isPluggedIn: snapshot.battery?.isPluggedIn ?? false
        )
        let stateChanged = lastChargeState.map { $0 != charge } ?? true
            || assertionActive != lastAssertionActive
        lastChargeState = charge
        lastAssertionActive = assertionActive

        let due = Date().timeIntervalSince(lastReload) >= Self.reloadInterval
        guard stateChanged || due else { return }
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
