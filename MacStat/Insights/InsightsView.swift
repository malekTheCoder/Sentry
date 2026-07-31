import SwiftUI
import MacStatKit

/// Root of the Insights tab — Sentry's answer to "what should I actually do
/// to protect this Mac?".
///
/// **Layout, top to bottom:** header (title, machine name, Refresh) → the
/// protection-score hero → the per-category breakdown → the prioritised
/// recommendations, with locked rows and the upsell inline where the free
/// allowance runs out → the positive findings → anything the user has hidden,
/// behind a disclosure → the methodology footer.
///
/// **Same theming contract as `DashboardView`:** compute a `ThemePalette`
/// from the view model's live `Theme` plus the system colour scheme, inject
/// it once, and let every subview read `@Environment(\.themePalette)`. The
/// theme is read live rather than captured at `init` for the reason
/// `DashboardViewModel.theme` documents — this view's hosting controller is
/// built exactly once per app run.
struct InsightsView: View {
    @ObservedObject private var viewModel: InsightsViewModel
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var showsSuppressed = false

    @MainActor
    init(viewModel: InsightsViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
    }

    private var palette: ThemePalette {
        ThemePalette(theme: viewModel.theme, scheme: systemColorScheme)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                header
                content
                methodologyFooter
            }
            .padding(.horizontal, palette.spacing * 2)
            .padding(.bottom, palette.spacing * 2)
            .padding(.top, MainWindowView.navHeight + 8)
        }
        .themedBackdrop(palette)
        .environment(\.themePalette, palette)
        // The one automatic evaluation. Everything after this is
        // user-initiated — see `InsightsViewModel`'s note on why there is
        // deliberately no timer here.
        .task {
            if viewModel.report == nil {
                viewModel.refresh()
            }
        }
    }

    // MARK: - Header

    private var machineName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Protection Insights")
                    .font(palette.font(size: 19, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(machineName)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: palette.spacing)
            Button {
                viewModel.refresh(reloadPosture: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(palette.font(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isRefreshing)
            .accessibilityLabel("Refresh protection insights")
            .accessibilityHint(Text("Re-reads this Mac's security settings and recomputes every finding"))
        }
        .padding(.bottom, palette.spacing * 0.5)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report = viewModel.report, let gated = viewModel.gated {
            ProtectionScoreCard(
                score: report.score,
                isRefreshing: viewModel.isRefreshing,
                postureCollectedAt: report.postureCollectedAt
            )
            CategoryBreakdownCard(score: report.score)

            if !report.hasEnoughHistory {
                thinHistoryNotice(report)
            }

            recommendations(report: report, gated: gated)
            positives(gated: gated)
            suppressedSection(report)
        } else {
            loadingCard
        }
    }

    private var loadingCard: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            Text("Working it out…")
                .font(palette.font(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("Reading this Mac's security settings and its recorded history. This takes a moment the first time.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard(palette)
        .accessibilityElement(children: .combine)
    }

    /// The honest "not enough data yet" state. Never a fabricated finding,
    /// never a spinner that never resolves — a specific number of days, and
    /// an explicit statement that the security half is unaffected.
    private func thinHistoryNotice(_ report: ProtectionInsightsReport) -> some View {
        let coverage = InsightPhrasing.days(report.historyCoverageDays)
        let needed = InsightPhrasing.days(report.additionalDaysNeeded)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text("Still gathering history")
                    .font(palette.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            Text("Sentry has \(coverage) of recorded telemetry for this Mac. The longevity findings — battery wear, thermal exposure, disk headroom — need about \(needed) more before they can say anything defensible, so they are staying quiet rather than guessing.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The security and privacy findings below are unaffected — they are read directly from this Mac's current settings, not from history.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard(palette)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func recommendations(report: ProtectionInsightsReport, gated: ProGate.GatedInsights) -> some View {
        let actionable = gated.unlocked.filter { $0.severity != .good }
        if !actionable.isEmpty || gated.isGated {
            sectionHeader("Recommendations")
            ForEach(actionable) { insight in
                row(for: insight, suppression: nil)
            }
            if gated.isGated {
                ProUpsellCard(gated: gated, unlockSource: viewModel.unlockSource)
                VStack(spacing: 6) {
                    ForEach(gated.locked) { preview in
                        LockedInsightRowView(preview: preview)
                    }
                }
            }
        } else if report.actionable.isEmpty {
            allClearCard
        }
    }

    private var allClearCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.success)
                    .accessibilityHidden(true)
                Text("Nothing to act on")
                    .font(palette.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            Text("Every rule Sentry could evaluate on this Mac came back clean. That is the expected result on a well-kept machine, not a placeholder — the findings below are the checks that passed.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard(palette)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func positives(gated: ProGate.GatedInsights) -> some View {
        let good = gated.unlocked.filter { $0.severity == .good }
        if !good.isEmpty {
            sectionHeader("Working well")
            ForEach(good) { insight in
                row(for: insight, suppression: nil)
            }
        }
    }

    @ViewBuilder
    private func suppressedSection(_ report: ProtectionInsightsReport) -> some View {
        if !report.suppressed.isEmpty {
            sectionHeader("Hidden by you")
            Button {
                showsSuppressed.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsSuppressed ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(hiddenSummary(count: report.suppressed.count))
                        .font(palette.font(size: 11))
                }
                .foregroundStyle(palette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hiddenSummary(count: report.suppressed.count))
            .accessibilityAddTraits(.isButton)

            if showsSuppressed {
                ForEach(report.suppressed) { insight in
                    row(for: insight, suppression: viewModel.activeSuppression(for: insight.id))
                }
            }
        }
    }

    /// Says plainly that hiding a finding also takes it out of the score —
    /// otherwise the number would quietly account for things the user can no
    /// longer see, which is the definition of an unauditable score.
    private func hiddenSummary(count: Int) -> String {
        let countText = "\(count)"
        return count == 1
            ? String(localized: "1 finding is hidden, and is not counted in the score.")
            : String(localized: "\(countText) findings are hidden, and are not counted in the score.")
    }

    private func row(for insight: ProtectionInsight, suppression: InsightSuppression?) -> some View {
        InsightRowView(
            insight: insight,
            suppression: suppression,
            onAction: { viewModel.perform($0) },
            onDismiss: { viewModel.dismiss(insightID: insight.id) },
            onSnooze: { viewModel.snooze(insightID: insight.id, for: $0) },
            onRestore: { viewModel.restore(insightID: insight.id) }
        )
    }

    // MARK: - Footer

    /// The disclosure that makes the whole feature checkable. A paid
    /// recommendation the user can't audit is a horoscope.
    private var methodologyFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How this is worked out")
                .font(palette.font(size: 10, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Text("Every finding is compared against this Mac's own recorded history — never against another machine or a fixed idea of \"normal\". Security settings are read with the same commands you could run yourself, without administrator rights; anything that needs privileges Sentry doesn't ask for is reported as unknown rather than guessed, and unknowns never count for or against the score.")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let report = viewModel.report {
                Text("Report generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(.top, palette.spacing)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(palette.font(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(palette.textTertiary)
            .padding(.top, palette.spacing)
            .accessibilityAddTraits(.isHeader)
    }
}
