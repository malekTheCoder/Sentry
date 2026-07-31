import Foundation

// MARK: - HistoryRange: the iPhone History tab's range selector (plan §12.1)

/// The iOS History tab's "24h / 7d / 30d / 90d / All" range selector,
/// mirroring `MacStat/Dashboard/TimeRangePicker.swift`'s enum-case spirit for
/// cross-app consistency without literally importing that type — it lives in
/// the `MacStat` *app* target, and Xcode app targets can't import each other
/// (same constraint `MacStatMobile/Theme/ThemeColor+SwiftUI.swift`'s doc
/// comment documents for theming, `MacStatMobile/Dashboard/MetricFormatting.swift`
/// for formatting).
///
/// **Why this pure enum lives in `MacStatKit`, not next to the SwiftUI
/// segmented control that renders it in `MacStatMobile/History/`.**
/// `MacStatTests` (`project.yml`) depends on `MacStatKit_macOS` and `MacStat`
/// only — there is no iOS test target in this build, so nothing under
/// `MacStatMobile/` is reachable from a test. `Freshness.swift` in this same
/// directory made the identical call for the identical reason (see its doc
/// comment). Splitting "the pure since/label mapping" (here, testable) from
/// "the `Picker` that renders it" (`MacStatMobile/History/HistoryRangeSelector.swift`,
/// not testable, and doesn't need to be — it has no logic of its own) matches
/// `TimeRangePicker`/`TimeRangePickerView`'s own split on the Mac side.
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case last24Hours, last7Days, last30Days, last90Days, all

    public var id: String { rawValue }

    /// Segmented-control label — short, matching `TimeRangePicker.label`'s
    /// own "fits a fixed-width control" constraint.
    public var label: String {
        switch self {
        case .last24Hours: return String(localized: "24H")
        case .last7Days: return String(localized: "7D")
        case .last30Days: return String(localized: "30D")
        case .last90Days: return String(localized: "90D")
        case .all: return String(localized: "All")
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .last24Hours: return String(localized: "Last 24 hours")
        case .last7Days: return String(localized: "Last 7 days")
        case .last30Days: return String(localized: "Last 30 days")
        case .last90Days: return String(localized: "Last 90 days")
        case .all: return String(localized: "All history")
        }
    }

    /// The lower bound of the window this range describes. `now` is an
    /// explicit parameter, not read internally, purely for testability —
    /// matching `TimeRangePicker.queryWindow(now:)`'s and
    /// `Freshness.init(lastSeen:now:)`'s identical convention elsewhere in
    /// this codebase.
    ///
    /// Nothing in this build actually queries a real `DailyHealth` store by
    /// date range yet (see `SyntheticDailyHealth`'s doc comment) — this
    /// property exists so that day is a one-line change at the call site
    /// rather than a new method, and so the "what does each range actually
    /// mean, as a date" question has one obviously-correct, tested answer
    /// today.
    public func since(now: Date = Date()) -> Date {
        switch self {
        case .last24Hours: return now.addingTimeInterval(-86400)
        case .last7Days: return now.addingTimeInterval(-7 * 86400)
        case .last30Days: return now.addingTimeInterval(-30 * 86400)
        case .last90Days: return now.addingTimeInterval(-90 * 86400)
        case .all:
            // Matches `TimeRangePicker.all`'s own reasoning: "all" means
            // all, and comparing against `.distantPast` is always true
            // without this type guessing how far back history could go.
            return .distantPast
        }
    }

    /// How many synthetic `DailyHealth` days `SyntheticDailyHealth.series`
    /// should fabricate for this range. This is the mock-data-era
    /// counterpart to `since(now:)`: a real CloudKit query would instead
    /// vary its date predicate against however much history actually
    /// exists, but there is no real history to query (see
    /// `SyntheticDailyHealth`'s doc comment) — this build instead varies
    /// *how many fake days it invents*.
    ///
    /// `.last24Hours` still asks for 2 days, not 1 — `DailyHealth` is
    /// daily-granularity, so a literal "last 24 hours" of it is at most a
    /// single point, which draws as a dot, not a trend line. Two days is the
    /// minimum that still renders a legible one-segment line rather than
    /// collapsing the chart to nothing; it is an honest reflection of "this
    /// metric doesn't really have an hourly story to tell," not an attempt
    /// to hide that fact.
    ///
    /// `.all` caps at 365 rather than being unbounded: unlike a real
    /// history query, which returns however many days actually exist, this
    /// generator invents a series with no real starting point, so an
    /// "unbounded" request has no natural length for it to resolve to.
    public var syntheticDayCount: Int {
        switch self {
        case .last24Hours: return 2
        case .last7Days: return 7
        case .last30Days: return 30
        case .last90Days: return 90
        case .all: return 365
        }
    }
}
