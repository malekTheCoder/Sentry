import SwiftUI
import SentryKit

/// Tab 2 — History (plan §12.1: range selector, battery health trend, cycle
/// count over time, charge/discharge session list, per-metric history
/// browser).
///
/// **Data source honesty.** Same constraint as `DashboardTabView`
/// (`SentryMobile/Dashboard/DashboardTabView.swift`, separate,
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

    /// Same gating `DashboardTabView` applies to its own `demoDataBanner` —
    /// see that type's doc comment. Note the battery-health trend chart
    /// stays honestly empty (not fabricated) once a real `LocalSyncClient`
    /// connection is live, since `AppDataSource.dailyHealthHistory(deviceID:
    /// dayCount:)` returns `[]` rather than synthetic data for that case
    /// (`SentryMobile/Data/AppDataSource.swift`'s doc comment) — the banner
    /// only needs to stop claiming *fabrication* once data is genuinely real,
    /// which `isUsingLocalSync` is the accurate signal for.
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
                if !appDataSource.isUsingLocalSync {
                    demoDataBanner
                }
                HistoryRangeSelector(selection: $viewModel.selectedRange)
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

    // MARK: - Demo data disclosure

    /// **Connection-honesty review, bug #6.** Used to say "this build has no
    /// live iCloud sync yet" — true in isolation, but shown exactly when
    /// `!appDataSource.isUsingLocalSync`, i.e. precisely when this phone
    /// isn't reachable to a Mac over the local network right now. iCloud was
    /// never the transport this build tries; naming it here told the reader
    /// their real, fixable problem (Mac unreachable on Wi-Fi) was actually
    /// an unrelated, unfinished cloud feature. Reworded to name the actual
    /// cause: no local-network connection right now, same signal
    /// `DashboardTabView`'s connection line and `SettingsTabView`'s device
    /// card already key off.
    private var demoDataBanner: some View {
        Label {
            Text("Showing demo data — not currently connected to a Mac on your local network")
                .scaledFont(palette, size: 12)
                .foregroundStyle(palette.textSecondary)
        } icon: {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(palette.warning)
        }
        .padding(palette.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
        .accessibilityElement(children: .combine)
        .accessibilityHint("This tab's numbers are synthesized, not a real Mac's history, because this phone isn't currently connected to a Mac over your local Wi-Fi network or a configured remote address — not because of any iCloud limitation.")
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
            Text(batteryHealthHeadline)
                .scaledFont(palette, size: 13, weight: .semibold)
                .foregroundStyle(palette.textPrimary)
            BatteryHealthTrendChart(series: viewModel.dailyHealth)
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
