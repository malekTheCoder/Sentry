import MacStatKit
import WidgetKit

// MARK: - MacStatWidgetEntry

/// One point on the widget's timeline: a `WidgetSnapshot` (or `nil`, if
/// `WidgetSnapshotStore` has nothing yet — see that type's doc comment on
/// why every failure mode collapses to `nil` rather than throwing) paired
/// with the `Date` WidgetKit should render it at.
///
/// **Why every entry in one `Timeline` carries the *same* `snapshot`.**
/// This cache is polled, not pushed — nothing re-runs `getTimeline` between
/// scheduled reloads, so there is no future value to put in a later entry
/// that this reload couldn't already see. Filling future entries with
/// identical data (rather than, say, only ever emitting one entry) still
/// matters: it's what lets `WidgetTimelineScheduler`'s multiple dates
/// actually produce multiple `.after`-policy reload attempts, since a
/// `Timeline` with one entry re-triggers `getTimeline` immediately once
/// that entry's date passes, at exactly the cadence
/// `WidgetTimelineScheduler` already decided. The `date` on each entry
/// still matters for its own reason: WidgetKit uses it to decide when to
/// swap which entry is on screen and to compute a fresh "how stale is this"
/// read if a view derives that from `entry.date` — none of the views here
/// do that (they use `snapshot.lastSeen` via `Freshness`, correctly, since
/// that's the age that matters — see `WidgetSnapshot`'s doc comment), but
/// keeping distinct dates is still what makes the timeline mechanism work
/// as WidgetKit expects.
struct MacStatWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

// MARK: - Provider

/// WidgetKit's thin adapter around `WidgetTimelineScheduler` (pure reload
/// cadence, `MacStatKit/Sync/WidgetTimelineScheduler.swift`) and
/// `WidgetSnapshotStore` (App Group read, `MacStatKit/Sync/WidgetSnapshot.swift`).
/// Deliberately has almost no logic of its own — every decision worth
/// getting right on its own (cadence, cap, honesty flag) already lives in a
/// unit-tested `MacStatKit` type; this just wires WidgetKit's callback shape
/// to those.
struct Provider: TimelineProvider {

    /// Shown briefly while WidgetKit waits for the real `getTimeline` result
    /// (e.g. right after the widget is added). WidgetKit automatically
    /// applies `.redacted(reason: .placeholder)` on top of whatever this
    /// renders, so the exact numbers here don't matter — only that the
    /// layout matches a real entry's, which is why this uses a fabricated
    /// `WidgetSnapshot` (with `sourceIsDemoData: true`, honestly, in case
    /// the redaction ever fails to apply) rather than `nil`, which would
    /// make the placeholder render the "No data yet" empty state instead of
    /// the actual widget layout.
    func placeholder(in context: Context) -> MacStatWidgetEntry {
        MacStatWidgetEntry(date: Date(), snapshot: Self.placeholderSnapshot)
    }

    /// The widget gallery's "add widget" preview. Uses the real cache when
    /// one exists (so the gallery preview looks like the app actually
    /// looks), falling back to the same placeholder sample otherwise —
    /// never `nil`, since an empty gallery preview would look broken rather
    /// than honestly stale.
    func getSnapshot(in context: Context, completion: @escaping (MacStatWidgetEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.read() ?? Self.placeholderSnapshot
        completion(MacStatWidgetEntry(date: Date(), snapshot: snapshot))
    }

    /// Reads the App Group cache exactly once per call (WidgetKit already
    /// only calls this at the cadence `WidgetTimelineScheduler` requested
    /// via the previous timeline's `.after` policy — re-reading per entry
    /// below would be redundant, not more current), then fans that single
    /// read across every date `WidgetTimelineScheduler.reloadDates` hands
    /// back. `nil` (nothing written yet, or the App Group is unreachable —
    /// see `WidgetSnapshotStore`'s doc comment) flows straight through:
    /// every entry view honestly renders its own "No data yet" state rather
    /// than this provider fabricating something to fill the gap.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacStatWidgetEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.read()
        let now = Date()
        let dates = WidgetTimelineScheduler.reloadDates(from: now)
        let entries = dates.map { MacStatWidgetEntry(date: $0, snapshot: snapshot) }
        let nextReload = dates.last ?? now.addingTimeInterval(WidgetTimelineScheduler.wakingCadence)
        completion(Timeline(entries: entries, policy: .after(nextReload)))
    }

    private static let placeholderSnapshot = WidgetSnapshot(
        deviceName: "Malek's MacBook Pro",
        lastSeen: Date(),
        writtenAt: Date(),
        sourceIsDemoData: true,
        batteryPercent: 78,
        isCharging: true,
        isPluggedIn: true,
        chargingWatts: 45,
        cpuPercent: 12,
        memoryUsedFraction: 0.55,
        sleepAssertion: .inactive,
        batteryHistory: (0..<12).map { i in
            WidgetBatteryHistoryPoint(
                date: Date().addingTimeInterval(TimeInterval(-i * 1200)),
                percent: Double(70 + (i % 5))
            )
        }.reversed()
    )
}
