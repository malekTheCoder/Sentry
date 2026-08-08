import SwiftUI
import SentryKit

/// Tab 2 — History (plan §12.1: range selector, battery health trend, cycle
/// count over time, charge/discharge session list, per-metric history
/// browser).
///
/// **Data source honesty.** When no Mac is reachable, every number on this
/// tab is fabricated by `MockDataSource`, not a real Mac's history — a
/// `FreshnessBadge` alone can only say "how old," never "how real," and this
/// tab has the second problem, not just the first.
///
/// This tab used to carry its own `demoDataBanner` card saying so, worded
/// differently from the Dashboard's amber connection line, both of which
/// scrolled away and neither of which existed on Alerts or Settings. That
/// card is **deleted**: `RootTabView` pins `DemoDataBanner`
/// (`SentryMobile/Disclosure/DemoDataBanner.swift`) above every tab, where it
/// cannot scroll away and cannot be worded two ways. What this tab keeps is
/// the inline `SAMPLE` tag on the battery-health card — the one surface here
/// that draws a chart a reader would otherwise take for their own Mac's
/// recorded history.
///
/// **What's built vs. honestly scoped down or omitted, against the plan's
/// five bullets for this tab:**
///   1. Range selector — `HistoryRangeSelector` / `HistoryRange`
///      (`SentryKit/History/HistoryRange.swift`).
///   2. Battery health trend — `BatteryHealthTrendChart`, backed by
///      `SyntheticDailyHealth` (`SentryKit/History/SyntheticDailyHealth.swift`).
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

    /// Read for one thing now — whether the battery-health card wears a
    /// `SAMPLE` tag. Note the trend chart stays honestly empty (not
    /// fabricated) once a real `LocalSyncClient` connection is live, since
    /// `AppDataSource.dailyHealthHistory(deviceID:dayCount:)` returns `[]`
    /// rather than synthetic data for that case
    /// (`SentryMobile/Data/AppDataSource.swift`'s doc comment) — so an
    /// untagged card is either real history or visibly no history, never
    /// fabrication passing as either.
    @EnvironmentObject private var appDataSource: AppDataSource

    /// Reads the theme `RootTabView` already resolved and injected over the
    /// whole `TabView`, the same way `DashboardTabView` does — this file
    /// used to compute its own hardcoded `ThemePalette(theme: .terminal...)`
    /// and re-inject it here, which silently overrode the user's actual
    /// picker selection for this tab's entire subtree the moment the
    /// Settings tab's theme picker landed in the same commit (both were
    /// built concurrently, before either could see the other's result).
    /// Two independent reviews caught this: picking a non-default theme
    /// visibly re-themed Dashboard but did nothing on History, which reads
    /// as "the app is broken" or "my choice didn't save" — neither true,
    /// the picker worked fine, this tab just never listened to it.
    @Environment(\.themePalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                title
                VStack(alignment: .leading, spacing: palette.spacingTight) {
                    HistoryRangeSelector(selection: $viewModel.selectedRange)
                    coverageCaption
                }
                batteryHealthCard
                chargeSessionGapNotice
                PerMetricHistoryBrowser(snapshot: viewModel.latestSnapshot)
            }
            .padding(palette.spacing * 2)
        }
        .themedScreenBackground(palette)
        .task { await viewModel.start() }
        .onChange(of: viewModel.selectedRange) { _, _ in
            Task { await viewModel.reloadDailyHealth() }
        }
    }

    // MARK: - Title

    private var title: some View {
        Text("History")
            .scaledFont(palette, size: 20, weight: .semibold)
            .foregroundStyle(palette.textPrimary)
    }

    // MARK: - Range coverage

    /// "30 days recorded", or "4 of 90 days recorded · since Jun 27" — under the
    /// range selector that produced the number.
    ///
    /// **Why the phone gets this too, when its demo series always fills the
    /// window.** `SyntheticDailyHealth` fabricates exactly `syntheticDayCount`
    /// days, so on the mock transport this caption permanently reads "N days
    /// recorded" and the chart never looks short. That is not a reason to skip
    /// it — it is the reason to build it now. The moment `AppDataSource
    /// .dailyHealthHistory` starts returning real records from a Mac (today it
    /// honestly returns `[]` over local sync, see its doc comment), the phone
    /// inherits the Mac's exact problem: a real record shorter than the selected
    /// range, drawn to fill the width. Both platforms offer the same five
    /// windows on the same data and must answer "how much of this do I actually
    /// have" the same way — the shared `HistoryCoverage` is what guarantees they
    /// word it identically rather than nearly identically.
    ///
    /// Placed directly under the selector, matching the Mac Dashboard header's
    /// placement of the same string beneath its own range control.
    @ViewBuilder
    private var coverageCaption: some View {
        if let summary = viewModel.coverage.summary {
            Text(summary)
                .scaledFont(palette, size: 11, monospacedDigit: true)
                .foregroundStyle(palette.textTertiary)
                .accessibilityLabel("History coverage: \(summary)")
        }
    }

    // MARK: - Demo data disclosure

    /// Whether this tab's fabricated surfaces wear a `SAMPLE` tag. Same
    /// `DemoDataDisclosure` decision the app-level banner is built from, for
    /// the same reason `DashboardTabView.marksDemoValues` derives it that way
    /// rather than re-testing a boolean: one definition of "demo," so a
    /// tagged chart under an absent banner is not a state this file can
    /// produce.
    ///
    /// The card-shaped `demoDataBanner` that used to live here — its own
    /// wording, its own icon, its own accessibility hint, scrolling away with
    /// the rest of the page — was deleted rather than reworded. See this
    /// type's doc comment.
    private var marksDemoValues: Bool {
        DemoDataDisclosure
            .prominence(isShowingDemoData: appDataSource.isShowingDemoData, isQuieted: false)
            .marksIndividualValues
    }

    // MARK: - Battery health

    /// Nocturne redesign spec: "Battery health · 92%" as a single headline
    /// line, the trend chart below it, and a "312 cycles" caption below
    /// that — folding what used to be two separate cards (this one, plus
    /// `CycleCountSection` rendered as its own elevated card underneath)
    /// into one. `CycleCountSection` itself is restyled to a slim inline
    /// caption for this (see that file) rather than duplicated here, so its
    /// range-delta logic stays in one place.
    private var batteryHealthCard: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            HStack(spacing: palette.spacingTight) {
                Text(batteryHealthHeadline)
                    .scaledFont(palette, size: 13, weight: .semibold)
                    .foregroundStyle(palette.textPrimary)
                if marksDemoValues {
                    DemoDataTag()
                }
                Spacer(minLength: 0)
            }
            BatteryHealthTrendChart(series: viewModel.dailyHealth, window: viewModel.window)
            CycleCountSection(series: viewModel.dailyHealth)
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
    }

    private var batteryHealthHeadline: String {
        let percent = MetricFormatting.percent(viewModel.dailyHealth.last?.healthPercent, decimals: 0)
        return String(localized: "Battery health · \(percent)")
    }

    // MARK: - Charge/discharge sessions (deliberately not built — see type doc comment)

    /// Nocturne redesign spec: a muted, *intentional*-looking disclosure —
    /// small outlined circle + one line of tertiary text — not the
    /// dashed-border callout box this used to be. The full "why" (no
    /// collector anywhere records session boundaries; `SystemSnapshot` is
    /// point-in-time, `DailyHealth` is a once-a-day aggregate) still lives
    /// as an accessibility hint, so it isn't lost for anyone who needs it,
    /// but the visible row is short enough to read as a deliberate design
    /// choice rather than a placeholder that broke.
    private var chargeSessionGapNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .scaledSystemFont(size: 9)
                .foregroundStyle(palette.textTertiary)
            Text("Charge sessions — not available yet on this build")
                .scaledFont(palette, size: 11)
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("No collector in this codebase records discrete charge or discharge session boundaries — SystemSnapshot is point-in-time and DailyHealth is a once-a-day aggregate.")
    }
}
