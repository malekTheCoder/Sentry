import Foundation
import MacStatKit

/// Pure, view-free formatting for `AlertRule` display on the iPhone's
/// Alerts tab — deliberately its own file/type rather than reusing
/// `AlertsPane`'s private `RuleKind`/`ComparisonKind` (`MacStat/Settings/Panes/AlertsPane.swift`),
/// which live in the `MacStat` (Mac app) module and aren't visible to
/// `MacStatMobile` (a separate iOS target). Rather than promote those types
/// to `MacStatKit` as a side effect of this tab — a real API-surface
/// decision that belongs to whoever owns `AlertsPane` next, not something
/// to sneak in here — this file re-derives the same small amount of display
/// logic `AlertsTabView` actually needs, in its own scope.
///
/// **Why this isn't exercised by `MacStatTests`.** `MacStatTests` is a
/// `bundle.unit-test` target built for macOS and linked against `MacStat`/
/// `MacStatKit_macOS`/`SystemMetricsKit` (see `project.yml`) — it cannot
/// depend on `MacStatMobile`, which is an iOS-platform-only application
/// target, the same way `MacStatKit_iOS` and `MacStatKit_macOS` have to be
/// two separate targets for one shared `MacStatKit/` source folder rather
/// than one target two platforms could share. Nothing in this file imports
/// UIKit or SwiftUI — it's plain `Foundation` + `MacStatKit` — so the
/// *logic* itself is exactly as testable as `AlertsPane`'s equivalent
/// (which `AlertsPaneFormattingTests` does cover); it's the platform-locked
/// test target wiring, not the code shape, that leaves it uncovered. Kept
/// deliberately small and low-branching (string formatting over already-
/// validated `AlertRule` data) to keep that gap low-risk rather than
/// papering over it with an untested surface that matters.
enum AlertRuleDisplay {

    /// One line describing what a rule actually checks, for the row
    /// subtitle in `AlertsTabView`. Mirrors the wording
    /// `AlertsPane.conditionSummary(for:)` produces on the Mac (same three
    /// cases: the two placeholder-metric special cases, the decrease-only
    /// battery health case, and the generic metric/comparison/threshold
    /// case) so a rule reads the same way in both places, without importing
    /// the Mac-only type that generates it there.
    static func conditionSummary(for rule: AlertRule) -> String {
        if rule.id == AlertEngine.chargingPausedRuleID {
            return "Plugged in but not charging, with a reason reported"
        }
        if rule.id == AlertEngine.slowChargingRuleID {
            return "Charging below half the adapter's rated wattage"
        }
        if rule.id == AlertEngine.batteryHealthDropRuleID {
            return "Health drops by \(MetricFormatter.detailed(rule.threshold, unit: .percent)) or more"
        }
        return "\(rule.metric.shortLabel) \(comparisonPhrase(rule.comparison)) \(MetricFormatter.detailed(rule.threshold, unit: rule.metric.unit))"
    }

    private static func comparisonPhrase(_ comparison: AlertRule.Comparison) -> String {
        switch comparison {
        case .above: return "at or above"
        case .below: return "at or below"
        case .equals: return "equals"
        case .changedBy: return "changed by"
        }
    }
}

// MARK: - AlertCategory

/// Section grouping for `AlertsTabView`'s rule list (Nocturne redesign
/// spec: "Grouped by category (Battery, Thermal, Performance, Disk) with a
/// small section header per group"). Derived from `AlertRule.metric.module`
/// (`MetricID.module`, `MacStatKit/Models/MetricID.swift`) rather than a
/// hand-maintained per-rule category field, so a rule categorizes itself
/// correctly just by which metric it reads. `MetricModule` has nine cases
/// (battery/cpu/gpu/ane/memory/disk/network/thermal/system); the spec's
/// four groups are coarser, so CPU/GPU/ANE/Memory/Network/System all fold
/// into "Performance" — none of `AppSettings.defaultAlertRules` reads a
/// network or system metric today, but the fallback keeps this exhaustive
/// against a future rule that does, rather than silently dropping it from
/// every section.
enum AlertCategory: String, CaseIterable, Identifiable {
    case battery, thermal, performance, disk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .battery: return "Battery"
        case .thermal: return "Thermal"
        case .performance: return "Performance"
        case .disk: return "Disk"
        }
    }

    init(module: MetricModule) {
        switch module {
        case .battery: self = .battery
        case .thermal: self = .thermal
        case .disk: self = .disk
        case .cpu, .gpu, .ane, .memory, .network, .system: self = .performance
        }
    }
}
