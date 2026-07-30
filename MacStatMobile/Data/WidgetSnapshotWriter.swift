import Foundation
import MacStatKit
import WidgetKit

// MARK: - WidgetSnapshotWriter: the phone app's half of plan §12.3's cache

/// Turns the live `SystemSnapshot` stream `DashboardViewModel` is already
/// observing into the small `WidgetSnapshot` cache `MacStatWidget` reads,
/// and asks WidgetKit to reload once each time.
///
/// **Why this exists as its own type instead of `DashboardViewModel` writing
/// directly.** `DashboardViewModel` is `@MainActor` UI state; this needs to
/// own the battery-history ring buffer (`WidgetBatteryHistory`,
/// `WidgetSnapshot.swift`) across snapshot ticks, which is bookkeeping the
/// view model has no other reason to carry. Keeping it a separate `actor`
/// also means the App-Group `UserDefaults` write and the
/// `WidgetCenter.reloadAllTimelines()` call — both un-@MainActor-scoped
/// system calls — don't need to hop off the main actor from inside a
/// `@Published`-owning object.
///
/// **Where the "demo data" honesty flag comes from.** `sourceIsDemoData` is
/// hardcoded `true` in `record(device:snapshot:)` below, not inferred —
/// this writer is only ever constructed against `MockDataSource`'s output
/// today (there is no other `StatsTransport` conformer in this build; see
/// that type's doc comment). The day a real `CloudKitTransport` exists and
/// this writer's caller starts feeding it real snapshots instead, that
/// call site is exactly where `sourceIsDemoData: false` should start being
/// passed through — this type doesn't try to guess "real vs. demo" from the
/// data itself, since a plausible-looking mock reading and a real one are
/// indistinguishable by design (`MockDataSource`'s whole point).
///
/// **Why `WidgetCenter.reloadAllTimelines()` rather than
/// `reloadTimelines(ofKind:)`.** This app currently ships exactly one
/// widget kind (`MacStatWidget.kind`, in `MacStatWidgetBundle.swift`), so
/// the two calls are behaviorally identical today; `reloadAllTimelines()` is
/// used anyway so this file doesn't have to import or hardcode a kind
/// string that lives in a different target (`MacStatWidget`) that
/// `MacStatMobile` doesn't depend on and shouldn't need to.
actor WidgetSnapshotWriter {

    private var history: [WidgetBatteryHistoryPoint] = []

    /// Call once per `SystemSnapshot` the phone app receives (today: once
    /// per `MockDataSource` tick, via `DashboardViewModel.observeSnapshots()`).
    /// Missing sub-structs (any Mac capability `SystemSnapshot` didn't
    /// report) fall back to `0`/`false`/`.inactive` for the *widget's*
    /// display purposes only — `SystemSnapshot` itself keeps those fields
    /// properly optional; this is a lossy, display-shaped projection, matching
    /// `SnapshotRecord`'s already-established precedent of duplicating a few
    /// scalars out of the full payload for cheap, best-effort rendering.
    func record(device: Device, snapshot: SystemSnapshot) {
        let batteryPercent = snapshot.battery?.chargePercent ?? 0
        let point = WidgetBatteryHistoryPoint(date: snapshot.timestamp, percent: batteryPercent)
        history = WidgetBatteryHistory.appending(point, to: history)

        let totalBytes = snapshot.memory?.totalBytes ?? 0
        let usedFraction: Double
        if totalBytes > 0, let usedBytes = snapshot.memory?.usedBytes {
            usedFraction = Double(usedBytes) / Double(totalBytes)
        } else {
            usedFraction = 0
        }

        let cached = WidgetSnapshot(
            deviceName: device.deviceName,
            lastSeen: device.lastSeen,
            writtenAt: Date(),
            sourceIsDemoData: true,
            batteryPercent: batteryPercent,
            isCharging: snapshot.battery?.isCharging ?? false,
            isPluggedIn: snapshot.battery?.isPluggedIn ?? false,
            chargingWatts: snapshot.battery?.chargingWatts,
            cpuPercent: snapshot.cpu?.totalPercent ?? 0,
            memoryUsedFraction: usedFraction,
            sleepAssertion: snapshot.sleepAssertion ?? .inactive,
            batteryHistory: history
        )

        WidgetSnapshotStore.write(cached)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
