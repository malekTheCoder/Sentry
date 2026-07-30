import SwiftUI
import MacStatKit

/// Tab 2 — History (plan §12.1: range selector, battery health trend, cycle
/// count over time, charge/discharge session list, per-metric history
/// browser).
///
/// **Data source honesty.** Same constraint as `DashboardTabView`
/// (`MacStatMobile/Dashboard/DashboardTabView.swift`, separate,
/// concurrently-built file): there is no live CloudKit sync in this build
/// (`MockDataSource`'s doc comment), so every number on this tab is
/// fabricated, not a real Mac's history. `demoDataBanner` below says so
/// explicitly, matching `DashboardTabView`'s identical banner — a
/// `FreshnessBadge` alone can only say "how old," never "how real," and
/// this tab has the second problem, not just the first.
///
/// **What's built vs. honestly scoped down or omitted, against the plan's
/// five bullets for this tab:**
///   1. Range selector — `HistoryRangeSelector` / `HistoryRange`
///      (`MacStatKit/History/HistoryRange.swift`).
///   2. Battery health trend — `BatteryHealthTrendChart`, backed by
///      `SyntheticDailyHealth` (`MacStatKit/History/SyntheticDailyHealth.swift`).
///   3. Cycle count over time — `CycleCountSection`, scoped to
///      current-value + range delta rather than a second chart; see that
///      view's doc comment for why.
///   4. Charge/discharge session list — **not built.** There is no
///      session-boundary data anywhere in this codebase: `SystemSnapshot`
///      is point-in-time, `DailyHealth` is a once-a-day aggregate, and no
///      collector anywhere marks "a charge session started/ended here."
///      Inventing plausible start/end timestamps for sessions that never
///      happened would be exactly the kind of confident-looking
///      fabrication `SyncPane.swift`'s doc comment (house rule P5, "never
///      overclaim") documents as a bug this codebase has shipped before in
///      different clothes. `chargeSessionGapNotice` below says why the
///      section is missing, so the gap reads as a documented choice, not an
///      oversight or a forgotten TODO.
///   5. Per-metric history browser — scoped down to a browsable list of
///      *current* per-metric values (`PerMetricHistoryBrowser`), not a full
///      synthetic history per metric; see that view's doc comment for why.
struct HistoryTabView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @Environment(\.colorScheme) private var systemColorScheme

    /// Matches `DashboardTabView`'s own hardcoded `.terminal` default — no
    /// theme picker exists yet on this platform (Settings tab is separate,
    /// parallel work), so a first launch looking intentional beats an
    /// arbitrary choice made independently per tab.
    private var palette: ThemePalette {
        ThemePalette(theme: .terminal, scheme: systemColorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                    demoDataBanner
                    HistoryRangeSelector(selection: $viewModel.selectedRange)
                    batteryHealthCard
                    CycleCountSection(series: viewModel.dailyHealth)
                    chargeSessionGapNotice
                    PerMetricHistoryBrowser(snapshot: viewModel.latestSnapshot)
                }
                .padding(palette.spacing * 2)
            }
            .background(palette.background)
            .navigationTitle("History")
        }
        .environment(\.themePalette, palette)
        .task { await viewModel.start() }
        .onChange(of: viewModel.selectedRange) { _, _ in
            Task { await viewModel.reloadDailyHealth() }
        }
    }

    // MARK: - Demo data disclosure

    private var demoDataBanner: some View {
        Label {
            Text("Showing demo data — this build has no live iCloud sync yet")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        } icon: {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(palette.warning)
        }
        .padding(palette.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius))
    }

    // MARK: - Battery health

    private var batteryHealthCard: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Battery Health")
                        .font(palette.font(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Synthetic trend — \(viewModel.dailyHealth.count) day(s)")
                        .font(palette.font(size: 10))
                        .foregroundStyle(palette.textTertiary)
                }
                Spacer(minLength: palette.spacing)
                Text(MetricFormatting.percent(viewModel.dailyHealth.last?.healthPercent, decimals: 1))
                    .font(palette.font(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
            }
            BatteryHealthTrendChart(series: viewModel.dailyHealth)
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    // MARK: - Charge/discharge sessions (deliberately not built — see type doc comment)

    private var chargeSessionGapNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Charge / Discharge Sessions", systemImage: "bolt.horizontal")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("Not available yet. No collector in this codebase records discrete charge/discharge session boundaries — SystemSnapshot is point-in-time and DailyHealth is a once-a-day aggregate, neither of which has a session start/end to report. This section is left honest about that gap rather than showing invented session data.")
                .font(.caption)
                .foregroundStyle(palette.textTertiary)
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: palette.cornerRadius)
                .strokeBorder(palette.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}
