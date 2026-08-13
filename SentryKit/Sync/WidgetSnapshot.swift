import Foundation

// MARK: - WidgetSnapshot: the small, App-Group-shared cache the widget reads

/// The tiny slice of a `SystemSnapshot` the widget (plan §12.3) actually
/// needs to render its five families, plus enough provenance
/// (`sourceIsDemoData`, `writtenAt`) that a widget reading this value can be
/// honest about what it's showing without re-deriving that honesty from
/// scratch.
///
/// **Why a separate type from `SystemSnapshot`.** Two reasons, both
/// deliberate:
///   1. `SystemSnapshot` is the full-fidelity in-process payload — dozens of
///      optional fields across seven sub-structs. The widget extension is a
///      separate process with its own (much smaller) memory/CPU budget and
///      WidgetKit's own size limits on what a `TimelineProvider` can
///      reasonably read every reload; shipping the whole `SystemSnapshot`
///      through the App Group for five stat lines and a sparkline is more
///      surface area than the job needs.
///   2. A shared projection is a *different, deliberately narrower shape*
///      than the canonical in-process model, not a re-export of it — the
///      pattern the deleted CloudKit record types originally established
///      (see git history), still the right call here.
///
/// **Why `sourceIsDemoData` is a stored field, not something the widget
/// infers.** `DashboardTabView`'s `demoDataBanner` (see that file's doc
/// comment) exists because `FreshnessBadge` alone can say "2 minutes old"
/// without ever saying "and there has never been a real Mac on the other
/// end of this." A widget pinned to someone's home screen showing "78% ·
/// 45W · CPU 12%" with total visual confidence is the single most
/// convincing way this app could accidentally lie — it has no companion
/// banner, no settings pane nearby, just a number in a system font. Baking
/// the demo flag into the cached value itself (rather than "the widget
/// assumes demo data because `MockDataSource` is all that exists today")
/// means the honesty travels with the data: when a live `LocalSyncClient`
/// connection writes this cache instead of `MockDataSource`, the
/// widget's disclosure automatically turns off because the writer sets
/// `sourceIsDemoData: false`, not because someone remembered to delete a
/// hardcoded label in `SentryWidget/`.
///
/// **Why this lives in `SentryKit`, not `SentryMobile` or
/// `SentryWidget`.** Both the phone app (writer) and the widget extension
/// (reader) need the exact same `Codable` shape — putting it in either
/// target would force the other to either depend on that target (wrong
/// direction for an app extension) or duplicate the struct (guaranteed
/// drift). `SentryKit_iOS` is already a dependency of both
/// (`project.yml`), and this type has no App-Group-specific API of its own
/// — `WidgetSnapshotStore` below is where the actual shared-container access
/// lives, kept separate so this struct stays a plain value type testable
/// with nothing but `Codable` round-tripping.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// Human-readable label for whichever Mac this came from — e.g.
    /// `Device.deviceName`. Not the full `Device` record: the widget has no
    /// use for `chip`/`osVersion`/`capabilitiesJSON`.
    public var deviceName: String

    /// When the *underlying reading* was taken on the source side —
    /// `Device.lastSeen`/`SystemSnapshot.timestamp`'s equivalent for this
    /// projection. This is what `Freshness(lastSeen:)` should be computed
    /// against inside the widget, not `writtenAt` below — a cache written
    /// seconds ago from a reading that is itself an hour stale must still
    /// render as stale, not as fresh just because the write was recent.
    public var lastSeen: Date

    /// When this specific cache entry was written to the App Group
    /// container. Separate from `lastSeen` for the reason above; kept
    /// mainly for diagnostics (e.g. "the writer hasn't run in N days" is a
    /// different failure mode than "the Mac hasn't reported in N days").
    public var writtenAt: Date

    /// Whether this value was fabricated by `MockDataSource` rather than
    /// synced from a real Mac. See this type's top-level doc comment for why
    /// this travels with the data instead of being assumed by the reader.
    public var sourceIsDemoData: Bool

    // MARK: Battery

    public var batteryPercent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var chargingWatts: Double?

    // MARK: CPU / Memory (medium/large families only)

    public var cpuPercent: Double
    /// 0...1, matches `MemoryStats.usedBytes / totalBytes` — kept as a
    /// fraction rather than raw byte counts since the widget only ever
    /// renders it as a percentage and never needs the underlying bytes.
    public var memoryUsedFraction: Double

    // MARK: Sleep assertion (medium/large families)

    public var sleepAssertion: SleepAssertionState

    // MARK: 24h battery sparkline (large family only)

    /// Recent battery-percent samples, oldest first. In this demo-data build
    /// this is genuinely "however much history `WidgetSnapshotWriter` has
    /// accumulated this run" — see that type's doc comment — capped well
    /// short of a true 24h/15-min-cadence series (that cadence is what a
    /// real synced build would populate this with; nothing here pretends
    /// otherwise since `sourceIsDemoData` already discloses it).
    public var batteryHistory: [WidgetBatteryHistoryPoint]

    public init(
        deviceName: String,
        lastSeen: Date,
        writtenAt: Date,
        sourceIsDemoData: Bool,
        batteryPercent: Double,
        isCharging: Bool,
        isPluggedIn: Bool,
        chargingWatts: Double?,
        cpuPercent: Double,
        memoryUsedFraction: Double,
        sleepAssertion: SleepAssertionState,
        batteryHistory: [WidgetBatteryHistoryPoint]
    ) {
        self.deviceName = deviceName
        self.lastSeen = lastSeen
        self.writtenAt = writtenAt
        self.sourceIsDemoData = sourceIsDemoData
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.chargingWatts = chargingWatts
        self.cpuPercent = cpuPercent
        self.memoryUsedFraction = memoryUsedFraction
        self.sleepAssertion = sleepAssertion
        self.batteryHistory = batteryHistory
    }
}

/// One point of `WidgetSnapshot.batteryHistory`. A plain `(Date, Double)`
/// pair would do the same job, but tuples aren't `Codable`, and this needs
/// to round-trip through `JSONEncoder`/`JSONDecoder` across the App Group
/// boundary.
public struct WidgetBatteryHistoryPoint: Codable, Sendable, Equatable {
    public var date: Date
    public var percent: Double

    public init(date: Date, percent: Double) {
        self.date = date
        self.percent = percent
    }
}

// MARK: - WidgetBatteryHistory: pure ring-buffer trimming logic

/// The pure "append and cap" rule behind `WidgetSnapshot.batteryHistory`,
/// factored out of `SentryMobile`'s `WidgetSnapshotWriter` so it's testable
/// from `SentryTests` without constructing an actor, a `MockDataSource`, or
/// an App Group container — none of which the trimming rule itself has
/// anything to do with. `WidgetSnapshotWriter` owns *when* to append (once
/// per received `SystemSnapshot`) and *where* the result goes
/// (`WidgetSnapshotStore.write`); this owns only "given the existing points
/// and a new one, what's the array afterward."
public enum WidgetBatteryHistory {

    /// Cap on stored points. This is a demo-data build with no real 24h/
    /// 15-min-cadence feed (see `WidgetSnapshot.batteryHistory`'s doc
    /// comment) — the cap exists purely to keep the App-Group-shared value
    /// from growing unbounded for the lifetime of a long-running phone-app
    /// process, not to model any particular time window.
    public static let cap = 48

    /// Appends `point` to `existing`, trimming from the front if the result
    /// exceeds `cap`. Points are assumed already in chronological order
    /// (the caller only ever appends the newest reading) — this doesn't
    /// re-sort, matching the "trust the caller's ordering" convention
    /// `RollupJob` uses for its own append-only series.
    public static func appending(
        _ point: WidgetBatteryHistoryPoint,
        to existing: [WidgetBatteryHistoryPoint],
        cap: Int = cap
    ) -> [WidgetBatteryHistoryPoint] {
        var updated = existing
        updated.append(point)
        if updated.count > cap {
            updated.removeFirst(updated.count - cap)
        }
        return updated
    }
}

// MARK: - WidgetSnapshotStore: the App Group read/write boundary

/// Reads and writes `WidgetSnapshot` through the `group.dev.malekswilam.sentry`
/// App Group container shared between `SentryMobile` and
/// `SentryWidgetExtension` (plan §12.3).
///
/// **Why `UserDefaults(suiteName:)` rather than a file in the shared
/// container's `FileManager` directory.** One small `Codable` struct,
/// written on every snapshot tick and read on every widget timeline reload,
/// is squarely what `UserDefaults` is for — no partial-write/torn-file risk
/// to guard against (a single `set(_:forKey:)` is atomic from the reader's
/// perspective), and no need to manage a file URL, create-if-missing
/// directory logic, or a second failure mode (file I/O errors) beyond "is
/// the App Group container reachable at all." A larger payload (the actual
/// 24h/15-min history a real sync build would carry) would likely outgrow
/// this approach, but `batteryHistory` above is explicitly capped small.
///
/// **Why every entry point returns `nil`/no-throw instead of `throws`.**
/// Every failure mode here — App Group entitlement missing or
/// misprovisioned, no value written yet, a decode failure after a future
/// schema change — is something both call sites (`WidgetSnapshotWriter` in
/// `SentryMobile`, `SentryWidget`'s `TimelineProvider`) need to treat as
/// "render the honest empty/placeholder state," never as a crash. Matches
/// `MockDataSource.send(command:)`'s "don't throw for an expected absence"
/// stance elsewhere in this codebase.
public enum WidgetSnapshotStore {

    /// Must match `SentryMobile.entitlements` and `SentryWidget.entitlements`
    /// exactly — `UserDefaults(suiteName:)` silently returns a container
    /// scoped to *this process only* if the identifier doesn't match a group
    /// both targets are entitled to, rather than failing loudly. There is
    /// nowhere else in the tree this string is duplicated from except those
    /// two entitlements files.
    public static let appGroupIdentifier = "group.dev.malekswilam.sentry"

    /// The macOS suite is deliberately *not* an App Group: iOS-style
    /// `group.*` identifiers on macOS require a provisioning profile (Xcode
    /// enforces this at build time), which the ad-hoc/no-team dev signing
    /// this project builds with cannot produce. Both macOS processes that
    /// touch this cache — the menu bar app's `MacWidgetSnapshotWriter` and
    /// `SentryWidgetExtension_macOS` — are unsandboxed, so a plain named
    /// suite in `~/Library/Preferences` is readable by both. When the app
    /// gains real Developer ID signing, switch macOS back to
    /// `appGroupIdentifier` + entitlements in `project.yml`.
    public static let macSuiteIdentifier = "dev.malekswilam.sentry.widgetcache"

    private static let storageKey = "dev.malekswilam.sentry.widgetSnapshot.v1"

    /// `nil` when the suite isn't reachable (on iOS: the App Group
    /// entitlement isn't provisioned correctly for this build/signing
    /// configuration — see this type's top-level doc comment). Every other
    /// method below routes through this so there is exactly one place that
    /// can fail this way.
    private static var sharedDefaults: UserDefaults? {
        #if os(macOS)
        UserDefaults(suiteName: macSuiteIdentifier)
        #else
        UserDefaults(suiteName: appGroupIdentifier)
        #endif
    }

    /// Called by `SentryMobile`'s `WidgetSnapshotWriter` after every
    /// snapshot the phone app receives. Silently does nothing if the App
    /// Group isn't reachable — see the type doc comment on why this isn't
    /// `throws`.
    public static func write(_ snapshot: WidgetSnapshot) {
        guard let defaults = sharedDefaults else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Called by the widget's `TimelineProvider` on every reload. `nil`
    /// covers three genuinely different situations the caller can't
    /// distinguish from here (App Group unreachable, nothing written yet,
    /// or a stale/undecodable schema) — all three get the same honest
    /// "nothing to show" treatment at the call site, per this type's
    /// top-level doc comment.
    public static func read() -> WidgetSnapshot? {
        guard let defaults = sharedDefaults else { return nil }
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
