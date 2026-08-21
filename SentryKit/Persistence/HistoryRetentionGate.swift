import Foundation

/// The free/paid cut for `ProFeature.historyExport` (history export +
/// extended retention), as a pure function — same shape as `ProGate.apply`
/// and for the same reason: the gate is a function of a plain `Bool`, so
/// tests drive it without an entitlement store, a settings file, or a UI,
/// and no view or job ever queries entitlement itself. Lives beside
/// `RollupJob`/`HistoryExport` rather than in `SentryKit/Pro` for the same
/// reason `ThemeEditingGate` lives beside `Theme` rather than in
/// `SentryKit/Pro`: a gate's vocabulary belongs to the feature it gates,
/// not to the paywall.
///
/// **What the free tier genuinely gets:** every in-app history view — the
/// Dashboard's charts, scrubbing, coverage captions, the works — over the
/// shipped retention windows (48 h of raw samples, 90 d of hourly rollups,
/// daily rollups forever), and full freedom to *shrink* those windows.
/// Lowering retention is data minimization and is never gated, under the
/// house rule every paid feature here answers to: anything that releases,
/// reverts, stops, or removes stays free. It is the same rule that leaves
/// deleting a custom theme ungated in `ThemeEditingGate` and keeps the
/// *disable* control live on a locked process rule in
/// `AlertsPane.enableAffordanceWithheld`.
///
/// **What the paywall withholds:** raising retention above the shipped
/// defaults, and exporting history to a file. The free caps equal the
/// defaults on purpose — no free user ever loses a value they could have
/// had before this gate existed.
///
/// **Withheld, not obscured.** There is no content to leak here: the
/// withheld things are database rows that were never recorded (extended
/// retention) and a file that is never constructed (export). The locked
/// surfaces render the feature's own name and honest bounds, nothing else.
public enum HistoryProGate {

    /// The free-tier ceiling for `AppSettings.rawRetentionHours`. Equals
    /// the shipped default (`AppSettings.init`'s `rawRetentionHours: Int =
    /// 48`) — if that default ever changes, this cap must move with it, or
    /// the free tier silently gains or loses ground the paywall never
    /// claimed.
    public static let freeRawRetentionCapHours = 48

    /// The free-tier ceiling for `AppSettings.hourlyRetentionDays`. Equals
    /// the shipped default (`AppSettings.init`'s `hourlyRetentionDays: Int
    /// = 90`) — same must-move-together constraint as the raw cap above.
    public static let freeHourlyRetentionCapDays = 90

    /// Clamps a retention pair to what this copy is entitled to enforce.
    /// Upper bound only: a locked copy can hold *less* history than the
    /// caps (shrinking is never gated), and this function never raises a
    /// value or supplies a floor — `RollupJob.setRetention` already guards
    /// its own lower bound.
    ///
    /// **Called at the composition root, on the delivered values, before
    /// they reach `RollupJob`** — `settings.json` is user-editable (see
    /// `DiskEstimate`'s comments), so the Advanced pane's capped sliders
    /// are not enforcement, just honesty. `RollupJob` itself stays
    /// entitlement-blind on purpose, same one-way flow as
    /// `AlertEngine.updateRules`.
    ///
    /// **Lapse behavior.** A license that lapses with retention still set
    /// above the caps lands here too: the *stored* preference is never
    /// rewritten — re-unlocking restores it verbatim — but the values
    /// delivered to `RollupJob.setRetention` are the clamped ones, so rows
    /// older than the free window are pruned on the next rollup pass
    /// exactly as if the user had lowered the sliders to the caps
    /// themselves. Nothing is ever deleted beyond what the effective
    /// retention implies, and the pruning is not silent: the Advanced
    /// pane's locked state states the saved-versus-enforced gap in words
    /// (see `AdvancedPane`'s lapsed-retention notice) before it happens.
    public static func clampedRetention(
        isUnlocked: Bool,
        rawHours: Int,
        hourlyDays: Int
    ) -> (rawHours: Int, hourlyDays: Int) {
        guard !isUnlocked else { return (rawHours, hourlyDays) }
        return (
            rawHours: min(rawHours, freeRawRetentionCapHours),
            hourlyDays: min(hourlyDays, freeHourlyRetentionCapDays)
        )
    }
}
