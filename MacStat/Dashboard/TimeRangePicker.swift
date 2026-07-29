import SwiftUI
import MacStatKit

/// The Dashboard's time-range selector: five fixed windows, each pre-mapped
/// to the `(since, tier)` pair `HistoryStore` needs to answer it.
///
/// **Why the mapping lives on the enum, not derived from
/// `HistoryStore`'s own automatic tier selection:** `HistoryStore.samples(metric:since:)`'s
/// private `tier(for:)` already encodes "raw <48h, hourly <90d, daily
/// beyond" (see that file), and this picker's cases are deliberately chosen
/// to land clear of those boundaries rather than skate along them:
///   - `.oneHour` / `.oneDay` are both well under the 48h raw cutoff, so
///     both get full-resolution un-rolled-up samples.
///   - `.sevenDays` / `.thirtyDays` are both well under the 90d hourly
///     cutoff, so both use the hourly rollup (raw rows that old have
///     usually already been deleted by `RollupJob`'s raw retention anyway).
///   - `.all` has no natural upper bound, so it always asks for the daily
///     rollup — the only tier `RollupJob` keeps forever.
/// Picking tiers explicitly per range (instead of calling the
/// tier-inferring `samples(metric:since:)` convenience) also means the
/// Dashboard can request `samplesWithRange`'s min/max band uniformly, since
/// that method takes an explicit `tier:` and has no auto-selecting overload.
enum TimeRangePicker: String, CaseIterable, Identifiable, Sendable {
    case oneHour, oneDay, sevenDays, thirtyDays, all

    var id: String { rawValue }

    /// Segmented-control label. Short on purpose — this sits in a
    /// fixed-width control, not prose.
    var label: String {
        switch self {
        case .oneHour: return "1H"
        case .oneDay: return "24H"
        case .sevenDays: return "7D"
        case .thirtyDays: return "30D"
        case .all: return "All"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .oneHour: return "Last hour"
        case .oneDay: return "Last 24 hours"
        case .sevenDays: return "Last 7 days"
        case .thirtyDays: return "Last 30 days"
        case .all: return "All history"
        }
    }

    /// The `(since, tier)` pair to pass to `HistoryStore.samplesWithRange`.
    /// Takes `now` as a parameter (rather than reading `Date()` internally)
    /// so tests can pin it and assert exact boundaries instead of racing the
    /// wall clock.
    func queryWindow(now: Date = Date()) -> (since: Date, tier: HistoryStore.Tier) {
        switch self {
        case .oneHour:
            return (now.addingTimeInterval(-3600), .raw)
        case .oneDay:
            return (now.addingTimeInterval(-86400), .raw)
        case .sevenDays:
            return (now.addingTimeInterval(-7 * 86400), .hourly)
        case .thirtyDays:
            return (now.addingTimeInterval(-30 * 86400), .hourly)
        case .all:
            // `.distantPast` rather than some large-but-finite lookback:
            // "All" means all, and a `ts >= sinceEpoch` comparison against
            // distantPast's (huge negative) epoch is always true without
            // this type having to guess how far back history could go.
            return (.distantPast, .daily)
        }
    }
}

// MARK: - Segmented control

/// Thin `Picker` wrapper so call sites get a ready-made segmented control
/// instead of every screen re-deriving `ForEach(TimeRangePicker.allCases)`
/// boilerplate. Deliberately not theme-styled beyond the system segmented
/// control's own appearance — unlike the module cards, this is a standard
/// AppKit-backed control (`.pickerStyle(.segmented)`), and re-skinning it to
/// match `ThemePalette` would fight the platform's native look for no
/// benefit the way a custom `Chart` does.
struct TimeRangePickerView: View {
    @Binding var selection: TimeRangePicker

    var body: some View {
        Picker("Time Range", selection: $selection) {
            ForEach(TimeRangePicker.allCases) { range in
                Text(range.label)
                    .accessibilityLabel(range.accessibilityLabel)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
