import Foundation

// MARK: - SyntheticDailyHealth: fabricated DailyHealth series for the demo build

/// Fabricates a plausible-looking, multi-day `DailyHealth` series (`SyncRecords.swift`)
/// for `SentryMobile/History` to chart, in lieu of a real CloudKit query.
///
/// **Why this needs to exist at all.** Plan §12.1 wants a "battery health
/// trend" chart and "cycle count over time" on the History tab. Both need a
/// *series* of `DailyHealth` records, but nothing in this codebase can
/// produce one: `CKMapper` (`SentryKit/Sync/CKMapper.swift`) can convert a
/// `DailyHealth` to/from a `CKRecord`, but no `SyncService`/transport
/// anywhere issues a `CKQuery` for the `DailyHealth` record type, and the
/// plan never specifies that fetch API's shape (deciding it is real,
/// separate design work this task doesn't own — same reasoning
/// `MockDataSource.devices()`'s doc comment gives for why the device catalog
/// fetch isn't part of `StatsTransport` either). Rather than block the whole
/// History tab on that undesigned API, this generates a fake series with the
/// same shape a real one would have.
///
/// **Why the math lives here, in `SentryKit`, rather than inside
/// `MockDataSource` (`SentryMobile/Data/MockDataSource.swift`), which is
/// the only thing that calls it.** `MockDataSource` is deliberately scoped
/// to `SentryMobile` — it is an iOS-app-only fake transport. But
/// `SentryTests` depends on `SentryKit_macOS`/`Sentry` only (`project.yml`)
/// — there is no iOS test target in this build, so nothing defined inside
/// `SentryMobile` is reachable from a test at all. Splitting "the
/// generation math" (here, pure, deterministic, testable) from "the
/// actor-isolated call site that exposes it as part of a mock transport"
/// (`MockDataSource.dailyHealthHistory(deviceID:dayCount:)`) is the same
/// shape `Freshness`/`FreshnessBadge` already use in this directory for a
/// different reason (cross-platform sharing) — pure logic goes where it's
/// testable and reusable, independent of which single call site uses it
/// today.
///
/// **Why "all history" doesn't mean an actually-unbounded series.** A real
/// `DailyHealth` query would return however many days of real history
/// happen to exist. This generator has no real history to reflect — it
/// invents one — so there is no natural answer to "how much fake history is
/// correct." `HistoryRange.all.syntheticDayCount` picks a fixed, generous
/// cap (365) instead of this type trying to guess.
///
/// **Determinism.** Seeded from `deviceID` via a plain FNV-1a hash (not
/// `Hasher`, whose seed is randomized per process launch by design and would
/// make two calls in the same run produce different output) so a given
/// device's synthetic history looks the same across repeated calls — a
/// battery trend chart that reshuffled itself every time the History tab
/// was revisited would read as a rendering bug, not demo data. Still applies
/// light jitter within each day, same spirit as
/// `MockDataSource.syntheticSnapshot`'s per-tick jitter, so the series isn't
/// a perfectly straight, obviously-synthetic line.
public enum SyntheticDailyHealth {

    /// Builds `dayCount` consecutive daily records ending at `endingAt`
    /// (inclusive of that calendar day), oldest first — matching the
    /// ascending-by-timestamp convention every `HistoryStore` read path in
    /// this codebase already guarantees.
    ///
    /// Health trends gently downward the further back a record is from
    /// `endingAt` (real lithium-ion batteries lose capacity over time/cycles,
    /// unlike the flat 94% `MockDataSource.syntheticSnapshot` reports for
    /// "right now" — a fixed number there is fine because that type only
    /// ever describes a single instant, but a *trend* chart with a flat line
    /// would look broken, not "healthy"). Cycle count is non-decreasing
    /// oldest-to-newest; `fullChargeCapacity` tracks `healthPercent`
    /// proportionally against `designCapacityMAh`, matching how the real
    /// field is defined (`SnapshotRecord.batteryHealth`'s sibling reasoning
    /// in `BatteryStats`).
    ///
    /// `dayCount <= 0` returns an empty array rather than asserting — a
    /// range change racing a not-yet-loaded device is a normal transient
    /// state for a caller to hit, not a programmer error.
    public static func series(
        deviceID: String,
        dayCount: Int,
        endingAt: Date = Date(),
        designCapacityMAh: Int = 6800
    ) -> [DailyHealth] {
        guard dayCount > 0 else { return [] }

        var generator = SeededGenerator(seed: fnv1aSeed(for: deviceID))
        let calendar = Calendar(identifier: .gregorian)
        let endDay = calendar.startOfDay(for: endingAt)

        var records: [DailyHealth] = []
        records.reserveCapacity(dayCount)
        // Fewer historical cycles for a shorter requested window, so a
        // freshly-generated 7-day series doesn't imply the device has only
        // existed for 7 days' worth of cycles while a 365-day one starts
        // from the same baseline — this is a cosmetic nod to plausibility,
        // not a claim about a real device's actual age.
        var cycleCount = max(40, 142 - dayCount / 3)

        // `offset` counts days before `endDay`: dayCount-1 (oldest) down to
        // 0 (newest/today). Iterating oldest-to-newest keeps `records` in
        // the ascending order every caller expects without a separate sort.
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDay) else { continue }

            let baseHealth = 100.0 - Double(offset) * 0.015
            let jitter = Double.random(in: -0.4...0.4, using: &generator)
            let health = min(100, max(70, baseHealth + jitter))
            let roundedHealth = (health * 10).rounded() / 10
            let fullChargeCapacity = Int((Double(designCapacityMAh) * roundedHealth / 100).rounded())
            let minCharge = ((Double.random(in: 12...28, using: &generator)) * 10).rounded() / 10
            let maxCharge = ((Double.random(in: 92...100, using: &generator)) * 10).rounded() / 10
            let timeOnACSeconds = Int(Double.random(in: 3 * 3600...14 * 3600, using: &generator))

            records.append(DailyHealth(
                deviceID: deviceID,
                day: day,
                healthPercent: roundedHealth,
                cycleCount: cycleCount,
                fullChargeCapacity: fullChargeCapacity,
                minCharge: minCharge,
                maxCharge: maxCharge,
                timeOnACSeconds: timeOnACSeconds
            ))

            // Roughly one additional cycle every couple of days moving
            // forward (toward "today") — keeps the series non-decreasing
            // without every single day ticking up, which would look overly
            // regular for something meant to resemble real usage.
            if offset.isMultiple(of: 2) { cycleCount += 1 }
        }
        return records
    }

    /// FNV-1a over the UTF-8 bytes of `deviceID`. Chosen over `Hasher`
    /// specifically because `Hasher`'s seed is randomized per process launch
    /// (by design, to resist hash-flooding) — that would make `series(...)`
    /// non-reproducible across two calls within the same test run, let alone
    /// across runs. FNV-1a has no such property and needs no external
    /// dependency for a use this small.
    private static func fnv1aSeed(for deviceID: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in deviceID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// A tiny deterministic PRNG conforming to `RandomNumberGenerator`, so
/// `SyntheticDailyHealth.series` can use the same `Double.random(in:using:)`
/// call shape `MockDataSource.syntheticSnapshot` already uses elsewhere in
/// this codebase, while still being reproducible for a given seed —
/// `SystemRandomNumberGenerator` (what `Double.random(in:)` uses without an
/// explicit generator) is intentionally non-reproducible. Splitmix64,
/// chosen only for being small and dependency-free; nothing here needs any
/// cryptographic property it doesn't have.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
