import Foundation

/// Pure "when should the widget's timeline ask WidgetKit to reload next"
/// logic for plan §12.3's cadence guidance, split out from
/// `MacStatWidget`'s `TimelineProvider` so it's testable without a
/// WidgetKit-hosting process — `MacStatWidgetExtension` isn't a dependency
/// of `MacStatTests` (nor should it become one just for this), and
/// `TimelineProvider.getTimeline(in:completion:)` itself has no pure
/// input/output shape to assert against directly. This type is the pure
/// core; `Provider` in `MacStatWidget/Provider.swift` is the thin WidgetKit
/// adapter around it, matching this codebase's existing split between pure
/// logic in `MacStatKit` and thin platform glue in the app targets (e.g.
/// `HeartbeatTracker` vs. wherever it's eventually called from
/// `AppDelegate`).
///
/// **Why this can't just be "every 15 minutes, always."** Plan §12.3 is
/// explicit that WidgetKit budgets roughly 40–70 reloads/day *total*, not
/// per-widget — at a flat 15-minute cadence around the clock that budget is
/// gone by hour 12, before "waking hours" even ends for most people, with
/// nothing left over for the "battery state changed" reloads the plan also
/// wants to prioritize. Spacing entries out overnight (`overnightCadence`)
/// buys back most of that budget for when a stale reading is most likely to
/// visibly matter (glancing at a phone during the day) rather than while
/// asleep next to a charging phone no one is looking at.
///
/// **Why this returns *only* a list of `Date`s, not `TimelineEntry`s or a
/// `Timeline`.** Building an actual `WidgetSnapshot`-backed entry per date
/// requires reading `WidgetSnapshotStore` — an App-Group-container read —
/// which is exactly the kind of environment-dependent side effect this type
/// is deliberately kept free of. `Provider` zips this type's dates against
/// one `WidgetSnapshotStore.read()` call (the same cached value repeated
/// across every future entry — see that type's doc comment on why the
/// widget cannot show live-changing data between reloads) to build the
/// actual `Timeline`.
public enum WidgetTimelineScheduler {

    /// Inclusive start of "typical waking hours," in the given `Calendar`'s
    /// local time. Plan §12.3 doesn't specify exact bounds beyond "typical
    /// waking hours" — 7am–11pm is a deliberately generous window (not
    /// everyone's literal wake time) since erring toward "reload during
    /// hours a lot of people are awake" costs a few extra reloads, while
    /// erring narrow risks a genuinely-awake user staring at a stale widget
    /// with no reload due for hours.
    public static let wakingHourStart = 7
    /// Exclusive end of waking hours.
    public static let wakingHourEnd = 23

    /// Cadence during waking hours — plan §12.3 item 1, verbatim.
    public static let wakingCadence: TimeInterval = 15 * 60
    /// Cadence outside waking hours. Four times as sparse as waking cadence,
    /// which happens to roughly quadruple the number of overnight hours one
    /// reload has to last without meaningfully changing how stale an
    /// overnight widget reads (`Freshness.staleThreshold` is already a full
    /// hour, so a 60-minute overnight cadence never even crosses into
    /// `.asleep` territory on its own).
    public static let overnightCadence: TimeInterval = 60 * 60

    /// How many entries one `Timeline` carries. WidgetKit itself caps how
    /// far in advance it will actually honor entries, and a longer array
    /// here just means more identical-looking placeholder entries (the
    /// underlying `WidgetSnapshot` doesn't change between them — see
    /// `Provider`) for no benefit; small and reload-driven is the plan's own
    /// recommended shape (`.after(lastEntryDate)` policy, not `.never`).
    public static let defaultEntryCount = 6

    /// Produces `count` reload timestamps starting at `now` (inclusive),
    /// spaced by `wakingCadence` while the *preceding* timestamp's hour
    /// falls in the waking window and `overnightCadence` otherwise — i.e.
    /// each gap is decided by where its start point falls, so a schedule
    /// that begins at 10:50pm steps to 11:05pm (still-waking gap) and only
    /// widens to hourly steps after that.
    ///
    /// `calendar` is an explicit parameter (defaulting to `.current`) so
    /// tests can pin a specific time zone rather than depending on the
    /// machine running the suite — matches `Freshness.init(lastSeen:now:)`'s
    /// "explicit `now`, not read internally" convention for the same
    /// testability reason.
    public static func reloadDates(
        from now: Date,
        calendar: Calendar = .current,
        count: Int = defaultEntryCount
    ) -> [Date] {
        guard count > 0 else { return [] }
        var dates: [Date] = []
        dates.reserveCapacity(count)
        var cursor = now
        for _ in 0..<count {
            dates.append(cursor)
            let hour = calendar.component(.hour, from: cursor)
            let isWaking = hour >= wakingHourStart && hour < wakingHourEnd
            cursor = cursor.addingTimeInterval(isWaking ? wakingCadence : overnightCadence)
        }
        return dates
    }
}
