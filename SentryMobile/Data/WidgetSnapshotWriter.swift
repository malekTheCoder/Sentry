import Foundation
import SentryKit
import WidgetKit

// MARK: - WidgetSnapshotWriter: the phone app's half of plan §12.3's cache

/// Turns the live `SystemSnapshot` stream `DashboardViewModel` is already
/// observing into the small `WidgetSnapshot` cache `SentryWidget` reads,
/// and asks WidgetKit to reload on a throttled cadence (see
/// `reloadIfWarranted` below — never once per tick).
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
/// passed in by the caller (`DashboardViewModel.observeSnapshots`), which
/// knows which transport produced the snapshot — `true` for
/// `MockDataSource`, `false` once `AppDataSource` has switched to a live
/// `LocalSyncClient` connection. This type doesn't try to guess "real vs.
/// demo" from the data itself, since a plausible-looking mock reading and a
/// real one are indistinguishable by design (`MockDataSource`'s whole
/// point). Mirrors `WatchRelayManager.consider(_:)`'s identical
/// `transport is MockDataSource` derivation for the Watch payload.
///
/// **Why `WidgetCenter.reloadAllTimelines()` rather than
/// `reloadTimelines(ofKind:)`.** This app currently ships exactly one
/// widget kind (`SentryWidget.kind`, in `SentryWidgetBundle.swift`), so
/// the two calls are behaviorally identical today; `reloadAllTimelines()` is
/// used anyway so this file doesn't have to import or hardcode a kind
/// string that lives in a different target (`SentryWidget`) that
/// `SentryMobile` doesn't depend on and shouldn't need to.
actor WidgetSnapshotWriter {

    private var history: [WidgetBatteryHistoryPoint] = []
    private var lastReload: Date = .distantPast
    private var lastChargeState: (isCharging: Bool, isPluggedIn: Bool)?
    private var lastAssertionActive = false

    /// Floor between routine `WidgetCenter` reloads — matches
    /// `MacWidgetSnapshotWriter.reloadInterval`; see `reloadIfWarranted`.
    private static let reloadInterval: TimeInterval = 300

    /// Call once per `SystemSnapshot` the phone app receives, via
    /// `DashboardViewModel.observeSnapshots()`. `sourceIsDemoData` is the
    /// caller's statement of which transport produced `snapshot` — see this
    /// type's doc comment. Missing sub-structs (any Mac capability `SystemSnapshot` didn't
    /// report) fall back to `0`/`false`/`.inactive` for the *widget's*
    /// display purposes only — `SystemSnapshot` itself keeps those fields
    /// properly optional; this is a lossy, display-shaped projection that
    /// duplicates a few scalars out of the full payload for cheap,
    /// best-effort rendering.
    func record(device: Device, snapshot: SystemSnapshot, sourceIsDemoData: Bool) {
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
            // `snapshot.timestamp`, not `device.lastSeen`: the synthesized
            // local-sync device catalog (`AppDataSource.devices()`) stamps
            // `lastSeen` once at fetch time, which would freeze the widget's
            // freshness badge at that moment; the snapshot's own timestamp
            // is when the reading was actually taken — same field the Mac
            // writer (`MacWidgetSnapshotWriter`) uses.
            lastSeen: snapshot.timestamp,
            writtenAt: Date(),
            sourceIsDemoData: sourceIsDemoData,
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
        reloadIfWarranted(snapshot: snapshot)
    }

    /// Mirrors `MacWidgetSnapshotWriter.reloadIfWarranted`
    /// (`Sentry/App/MacWidgetSnapshotWriter.swift`): the store write above
    /// is cheap and happens every tick, but `reloadAllTimelines()` is
    /// budgeted by WidgetKit (~40–70 reloads/day) and the snapshot stream
    /// ticks every few seconds — reloading per tick would exhaust the
    /// budget within hours and get the widget throttled. Reload immediately
    /// on a visible state change (charging toggled, sleep assertion
    /// flipped), otherwise no more often than `reloadInterval`; the widget
    /// re-polls the store on `WidgetTimelineScheduler`'s cadence regardless,
    /// so a skipped reload only delays a routine value refresh.
    private func reloadIfWarranted(snapshot: SystemSnapshot) {
        let charge = (
            isCharging: snapshot.battery?.isCharging ?? false,
            isPluggedIn: snapshot.battery?.isPluggedIn ?? false
        )
        let assertionActive: Bool
        if case .active = snapshot.sleepAssertion ?? .inactive {
            assertionActive = true
        } else {
            assertionActive = false
        }
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
