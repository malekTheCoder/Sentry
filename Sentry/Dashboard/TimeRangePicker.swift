import SwiftUI
import SentryKit

/// The Dashboard's time-range selector: five fixed windows, each pre-mapped
/// to the `(since, tier)` pair `HistoryStore` needs to answer it.
///
/// **Why the mapping lives on the enum, not derived from
/// `HistoryStore`'s own automatic tier selection:** `HistoryStore.samples(metric:since:)`'s
/// private `tier(for:)` already encodes "raw <48h, hourly <90d, daily
/// beyond" (see that file), and this picker's cases are deliberately chosen
/// to land clear of those boundaries rather than skate along them:
///   - `.day` is well under the 48h raw cutoff, so it gets full-resolution
///     un-rolled-up samples.
///   - `.week` / `.month` are both well under the 90d hourly cutoff, so
///     both use the hourly rollup (raw rows that old have usually already
///     been deleted by `RollupJob`'s raw retention anyway).
///   - `.quarter` (90d) sits right at that same hourly-tier boundary —
///     still comfortably answerable by the hourly rollup rather than
///     stepping down to daily, since `HistoryStore.tier(for:)` treats "under
///     90d" as hourly's own upper edge, not a cliff to back away from.
///   - `.halfYear` (6mo) is a real bounded window, unlike the old "All"
///     case this design replaces — it still asks for the daily rollup (the
///     only tier `RollupJob` keeps forever), but with an actual 6-month
///     `since` bound rather than `.distantPast`, since "6 months" has a
///     natural edge that "all history" never did.
/// Picking tiers explicitly per range (instead of calling the
/// tier-inferring `samples(metric:since:)` convenience) also means the
/// Dashboard can request `samplesWithRange`'s min/max band uniformly, since
/// that method takes an explicit `tier:` and has no auto-selecting overload.
enum TimeRangePicker: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, quarter, halfYear

    var id: String { rawValue }

    /// Segmented-control label. Short and lowercase per the Nocturne
    /// redesign mock — this sits in a fixed-width pill control, not prose.
    var label: String {
        switch self {
        case .day: return String(localized: "24h")
        case .week: return String(localized: "7d")
        case .month: return String(localized: "30d")
        case .quarter: return String(localized: "90d")
        case .halfYear: return String(localized: "6mo")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .day: return String(localized: "Last 24 hours")
        case .week: return String(localized: "Last 7 days")
        case .month: return String(localized: "Last 30 days")
        case .quarter: return String(localized: "Last 90 days")
        case .halfYear: return String(localized: "Last 6 months")
        }
    }

    /// The `(since, tier)` pair to pass to `HistoryStore.samplesWithRange`.
    /// Takes `now` as a parameter (rather than reading `Date()` internally)
    /// so tests can pin it and assert exact boundaries instead of racing the
    /// wall clock.
    func queryWindow(now: Date = Date()) -> (since: Date, tier: HistoryStore.Tier) {
        switch self {
        case .day:
            return (now.addingTimeInterval(-86400), .raw)
        case .week:
            return (now.addingTimeInterval(-7 * 86400), .hourly)
        case .month:
            return (now.addingTimeInterval(-30 * 86400), .hourly)
        case .quarter:
            return (now.addingTimeInterval(-90 * 86400), .hourly)
        case .halfYear:
            // A real 6-month bound rather than `.distantPast` — unlike the
            // old "All" case this replaces, "6 months" has a natural edge,
            // so there's no reason to ask the daily rollup for more than
            // that just because it's the tier that happens to keep rows
            // forever.
            return (now.addingTimeInterval(-182 * 86400), .daily)
        }
    }
}

// MARK: - Text range switcher

/// The redesign handoff's range switcher: plain text buttons separated by
/// middots — active is `textPrimary` semibold, inactive `textTertiary`.
/// No pill, no fill, no accent: a range is a view state, not an action,
/// and the handoff reserves accent strictly for actions.
struct TimeRangePickerView: View {
    @Environment(\.themePalette) private var palette

    @Binding var selection: TimeRangePicker

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(TimeRangePicker.allCases.enumerated()), id: \.element.id) { index, range in
                if index > 0 {
                    Text("·")
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                        .accessibilityHidden(true)
                }
                segment(for: range)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func segment(for range: TimeRangePicker) -> some View {
        let isSelected = range == selection
        return Button {
            selection = range
        } label: {
            Text(range.label)
                .font(palette.font(size: 11, weight: isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? palette.textPrimary : palette.textTertiary)
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(range.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
