import Foundation

/// Mac-side half of plan §7.4's "iPhone recently active" fast-cadence
/// trigger: "the iPhone write[s] a lightweight `lastViewedAt` field on the
/// `Device` record when the app is foregrounded. The Mac reads it and enters
/// fast-cadence mode for 10 minutes."
///
/// `Device.lastViewedAt: Date?` exists on the model type
/// (`SyncModels.swift`). This type still takes a plain `Date?` rather than
/// a whole `Device` — the decision only ever needs the one field, and
/// staying decoupled from the model type keeps it trivially testable and
/// reusable if an eventual scheduler wants to call it with a cached
/// value rather than a full record fetch.
///
/// This type is pure decision logic — no timers, no networking, no
/// `StatsCoordinator` coupling — so composition (wherever a real upload
/// cadence scheduler would eventually live, per plan §7.4's interval table)
/// can call `isFastCadence(lastViewedAt:now:)` on every tick and pick 30s vs
/// 5min accordingly. No caller does yet: the adaptive-cadence upload service
/// this was written for was deleted with the CloudKit layer (see git
/// history), and the LocalSync transport pushes snapshots as they arrive
/// rather than polling on a cadence. Deliberately not a class/actor: there
/// is no mutable state to isolate, only a computation over two `Date`
/// values, so `@MainActor` isolation (which every other piece in this batch
/// uses, matching `PowerControlService`'s precedent) would add ceremony
/// without protecting anything.
public enum HeartbeatTracker {

    /// How long "recently active" stays true after the last observed
    /// `lastViewedAt` (plan §7.4: "fast-cadence mode for 10 minutes").
    public static let fastCadenceWindow: TimeInterval = 10 * 60

    /// Whether the Mac should currently be in fast-cadence upload mode
    /// (plan §7.4's 30s interval), given the most recently observed
    /// `Device.lastViewedAt` and the current time.
    ///
    /// `nil` (never observed / not yet foregrounded since this process
    /// started tracking it) means "not recently active" — `false`, not an
    /// error. The boundary is inclusive of the window and exclusive at its
    /// edge: `now - lastViewedAt < window`, so a heartbeat from *exactly*
    /// the window's edge has just fallen out of fast-cadence mode (mirrors
    /// `RollupJob`'s `ts < cutoff` convention for "how long ago is still
    /// in-window" — see that file's hourly/daily rollup cutoff math).
    ///
    /// - Parameter window: defaults to `fastCadenceWindow`, but overridable
    ///   so a caller that exposes its own configurable window (or a test
    ///   that doesn't want to wait on real wall-clock minutes) can delegate
    ///   here instead of re-deriving the same comparison privately — the
    ///   now-deleted upload service once duplicated this logic in a second,
    ///   independently-tested place with no static guarantee the two would
    ///   stay in sync as either evolved.
    public static func isFastCadence(lastViewedAt: Date?, now: Date = Date(), window: TimeInterval = fastCadenceWindow) -> Bool {
        guard let lastViewedAt else { return false }
        return now.timeIntervalSince(lastViewedAt) < window
    }
}
