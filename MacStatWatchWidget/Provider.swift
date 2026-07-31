import MacStatKit
import WidgetKit

// MARK: - MacStatWatchWidgetEntry

/// One point on the complication's timeline — mirrors
/// `MacStatWidget/Provider.swift`'s `MacStatWidgetEntry` shape and reasoning
/// exactly (see that type's doc comment): this cache is pushed by
/// `WatchSessionController`, not polled, so every entry a single
/// `getTimeline` call produces carries the same `WatchRelaySnapshot?` —
/// there is no future value to fill later entries with that this call
/// couldn't already see.
struct MacStatWatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchRelaySnapshot?
}

// MARK: - Provider

/// WidgetKit's thin adapter around `WatchRelayStore`
/// (`MacStatKit/Watch/WatchRelayStore.swift`). Deliberately almost no logic
/// of its own, matching `MacStatWidget/Provider.swift`'s precedent.
///
/// **Reload cadence.** Unlike the iOS widget (`WidgetTimelineScheduler`,
/// polling a live local-sync connection on a real cadence), this
/// complication has nothing to poll — new data only ever arrives by
/// `WatchSessionController` calling `WidgetCenter.shared.reloadAllTimelines()`
/// after a push from the phone. The handful of future entries scheduled
/// below exist purely so the complication's *staleness label* (via
/// `Freshness`) keeps advancing even if the phone goes quiet for a while —
/// not to represent any new data, since there isn't any to represent.
struct Provider: TimelineProvider {
    /// Spacing between the placeholder-refresh entries below. 15 minutes
    /// keeps the staleness label reasonably current without asking
    /// WidgetKit to re-run `getTimeline` needlessly often for a value that,
    /// per this type's doc comment, never changes between pushes anyway.
    static let relabelCadence: TimeInterval = 15 * 60
    static let relabelEntryCount = 4

    func placeholder(in context: Context) -> MacStatWatchWidgetEntry {
        MacStatWatchWidgetEntry(date: Date(), snapshot: Self.placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacStatWatchWidgetEntry) -> Void) {
        let snapshot = WatchRelayStore.read() ?? (context.isPreview ? Self.placeholderSnapshot : nil)
        completion(MacStatWatchWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacStatWatchWidgetEntry>) -> Void) {
        let snapshot = WatchRelayStore.read()
        let now = Date()
        let dates = (0..<Self.relabelEntryCount).map {
            now.addingTimeInterval(Self.relabelCadence * TimeInterval($0))
        }
        let entries = dates.map { MacStatWatchWidgetEntry(date: $0, snapshot: snapshot) }
        // `.after` the last scheduled relabel — if a push arrives sooner,
        // `WatchSessionController` calling `reloadAllTimelines()` supersedes
        // this policy immediately; this is only the fallback for "nothing
        // arrived in the meantime."
        completion(Timeline(entries: entries, policy: .after(dates.last ?? now)))
    }

    private static let placeholderSnapshot = WatchRelaySnapshot(
        deviceName: "Malek's MacBook Pro",
        lastSeen: Date(),
        relayedAt: Date(),
        sourceIsDemoData: true,
        batteryPercent: 78,
        isCharging: true,
        isPluggedIn: true,
        thermalPressure: .nominal
    )
}
