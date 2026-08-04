import Foundation

// MARK: - Freshness: the iPhone app's core honesty mechanism (plan §12.2)

/// How old a Mac-derived reading is, bucketed into the four tiers the iPhone
/// UI renders a distinct color/icon/label for.
///
/// **Why this exists at all.** CloudKit sync (`StatsTransport`, `SyncRecords.swift`)
/// is eventually-consistent by construction, and — separately, today — doesn't
/// exist yet (no enrolled Apple Developer Program account; see
/// `StatsTransport.swift`'s doc comment). Either way, any number the iPhone
/// shows (battery %, CPU load, whether the Mac is asleep) is a *claim about
/// the past*, not a live reading. Plan §12.2 is explicit that the fix isn't
/// technical, it's presentational discipline: "Never render a number without
/// its freshness indicator nearby. This single discipline is the difference
/// between 'the app feels broken' and 'the app is honest about a fundamental
/// constraint.'" This type is that discipline made checkable — every screen
/// that shows Mac-derived data computes a `Freshness` from the same
/// `lastSeen` timestamp and renders it via `FreshnessBadge`, so "did I
/// remember the indicator" stops being a per-screen judgment call.
///
/// **Why it lives in `SentryKit`, not `SentryMobile`.** The four cases,
/// their thresholds, and the "is this reading trustworthy" question are pure
/// data-age logic with no iOS dependency — `Device.lastSeen` (`SyncRecords.swift`)
/// is exactly the kind of timestamp this wraps. Keeping it here means it's
/// available to whichever platform eventually renders sync-derived data,
/// same reasoning as `HeartbeatTracker` living here rather than in a
/// platform-specific target, and it's testable in `SentryTests`
/// (macOS-hosted) without needing an iOS test target to exist.
///
/// **Boundary convention.** Each threshold is the exclusive upper edge of the
/// tier below it — `age < threshold` — matching `HeartbeatTracker
/// .isFastCadence`'s and `RollupJob`'s existing "how long ago is still
/// in-window" convention elsewhere in this codebase, so a reading at exactly
/// 60.000s is `.recent`, not `.live`.
public enum Freshness: Equatable, Sendable {
    /// Age < 60s. Green dot, "Live".
    case live
    /// 60s <= age < 5min. Amber dot, "Nm ago".
    case recent
    /// 5min <= age < 1hr. Gray dot, "Nm ago".
    case stale
    /// Age >= 1hr. Moon icon, "Mac asleep — last seen Nh ago".
    case asleep
}

extension Freshness {

    /// Upper bound (exclusive) of `.live`.
    public static let liveThreshold: TimeInterval = 60
    /// Upper bound (exclusive) of `.recent`.
    public static let recentThreshold: TimeInterval = 5 * 60
    /// Upper bound (exclusive) of `.stale`; anything older is `.asleep`.
    public static let staleThreshold: TimeInterval = 60 * 60

    /// Buckets `lastSeen` against `now` into one of the four tiers.
    ///
    /// `now` defaults to `Date()` but is an explicit parameter (not read
    /// internally) purely for testability — every boundary test below passes
    /// a fixed `now` so the suite isn't racing the real clock, matching
    /// `HeartbeatTracker.isFastCadence`'s signature exactly.
    ///
    /// A `lastSeen` in the future (clock skew between devices, or a
    /// just-written heartbeat racing this computation) produces a negative
    /// age, which falls into `.live` rather than crashing or misclassifying
    /// — same defensive stance as `HeartbeatTracker.isFastCadence`'s
    /// "future lastViewedAt is fast cadence" case.
    public init(lastSeen: Date, now: Date = Date()) {
        let age = now.timeIntervalSince(lastSeen)
        if age < Self.liveThreshold {
            self = .live
        } else if age < Self.recentThreshold {
            self = .recent
        } else if age < Self.staleThreshold {
            self = .stale
        } else {
            self = .asleep
        }
    }

    /// The label text plan §12.2 specifies verbatim for each tier: `"Live"`,
    /// `"2m ago"`, `"18m ago"`, `"Mac asleep — last seen 3h ago"`.
    ///
    /// Takes `lastSeen`/`now` again (rather than caching the age at init
    /// time) so a long-lived `Freshness` value re-labels correctly if held
    /// across a re-render — in practice call sites recompute both together
    /// each time, but decoupling "which tier" from "what age string" avoids
    /// a second stored `TimeInterval` nobody asked for.
    public func label(lastSeen: Date, now: Date = Date()) -> String {
        switch self {
        case .live:
            return "Live"
        case .recent, .stale:
            return "\(Self.compactAge(from: lastSeen, to: now)) ago"
        case .asleep:
            return "Mac asleep — last seen \(Self.compactAge(from: lastSeen, to: now)) ago"
        }
    }

    /// SF Symbol name for the tier's icon. `.live`/`.recent`/`.stale` render
    /// as a plain filled dot (color alone carries the distinction, per plan
    /// §12.2's "green dot / amber dot / gray dot"); `.asleep` gets the moon
    /// glyph the plan calls for explicitly, since a fourth color alone
    /// wouldn't read as "categorically different" the way a shape change
    /// does — that asymmetry (3 colors + 1 icon, not 4 colors) is the plan's
    /// own design, not an embellishment added here.
    public var symbolName: String {
        switch self {
        case .live, .recent, .stale:
            return "circle.fill"
        case .asleep:
            return "moon.fill"
        }
    }

    /// Compact "2m" / "18m" / "3h" age string — minutes below an hour,
    /// whole hours at/above it. Deliberately simpler than
    /// `AlertsPane.humanDuration`: this only ever formats an *elapsed* age
    /// for display next to a freshness dot, never a configurable duration a
    /// user picked, so there's no "Fires immediately"/singular-plural
    /// hand-off to a zero-or-negative case — `max(0, ...)` alone covers the
    /// clock-skew edge from `init(lastSeen:now:)` above.
    /// Whether this tier is stale enough that a surface with no room for the
    /// full `FreshnessBadge` label — the Watch complication families other
    /// than `.accessoryRectangular`, see `ComplicationView.swift`'s doc
    /// comments — should still show *some* visual cue that the reading is
    /// not current.
    ///
    /// `.live` and `.recent` are excluded deliberately, not just for
    /// simplicity: `WatchRelayPolicy.minimumRelayInterval`
    /// (`SentryKit/Watch/WatchRelayPolicy.swift`) heartbeats every 5 minutes
    /// even when nothing has changed, so a reading "up to 5 minutes old" is
    /// the normal, healthy operation of the relay, not a problem worth
    /// flagging on a watch face. `.stale` (>= 5 minutes) is exactly the
    /// point at which the heartbeat itself has gone missing, which is the
    /// thing worth surfacing.
    public var warrantsCompactStalenessCue: Bool {
        switch self {
        case .live, .recent: return false
        case .stale, .asleep: return true
        }
    }

    private static func compactAge(from lastSeen: Date, to now: Date) -> String {
        let age = max(0, now.timeIntervalSince(lastSeen))
        let minutes = Int((age / 60).rounded(.down))
        if minutes < 60 {
            return "\(max(minutes, 1))m"
        }
        let hours = Int((age / 3600).rounded(.down))
        return "\(hours)h"
    }
}
