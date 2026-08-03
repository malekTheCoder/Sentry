import SwiftUI
import SentryKit

/// Tab 3 — Alerts (plan §12.1: "Recent alert feed, Rule enable/disable
/// (full editing stays on the Mac for v2)").
///
/// **Why the feed half of this tab is an honest empty state, not a feed.**
/// Plan §7.3 lists exactly five CloudKit record types — `Device`,
/// `Snapshot`, `DailyHealth`, `ControlCommand`, `ControlStatus`
/// (`SentryKit/Sync/SyncRecords.swift`) — and there is no `Alert` or
/// `AlertFiring` record type anywhere in the plan or this codebase. The
/// Mac's fired-alert history (`alert_log`, written by
/// `HistoryStore.logAlertFiring`/read by `HistoryStore.recentAlertFirings`)
/// is local SQLite only; nothing has ever serialized a row of it to
/// CloudKit, so there is no data path by which this iPhone process could
/// know what has fired on the Mac. Inventing a plausible-looking feed here
/// — synthetic timestamps, synthetic rule names — would be exactly the
/// "confident UI describing a reality that isn't true" bug `SyncPane.swift`
/// (`Sentry/Settings/Panes/SyncPane.swift`) was written to stop
/// reintroducing elsewhere in this app; `historyDisclosure` below keeps
/// that pane's direct, non-apologetic tone rather than something softer
/// like "coming soon." Designing the actual sync record type this needs is
/// a real architecture decision for the CloudKit sync work, not a call this
/// tab gets to make on its own.
///
/// **Why the rule list is real content, not a mock.** `AppSettings.defaultAlertRules`
/// (`SentryKit/Settings/AppSettings.swift`) is the exact 11-rule set
/// `AlertEngine.defaultRules(cooldown:)` builds and Sentry actually ships
/// with — showing it here is reporting a true fact about the Mac app, the
/// same way `SyncPane`'s cadence table shows `SyncService`'s real, tested
/// cadence constants "as documentation, not status." No firing history, no
/// per-Mac customization, and no live rule set are implied by this list —
/// see `ruleRow`'s doc comment for exactly what the enable/disable toggle
/// does and doesn't do.
///
/// **Nocturne redesign restyle.** Was a native `List`/`Section` (system
/// styling, no `ThemePalette` involvement at all — the only tab that never
/// read `\.themePalette`). Rebuilt as a themed `ScrollView` matching
/// Dashboard/History's card language, with rules now grouped under
/// Battery/Thermal/Performance/Disk section headers (`AlertCategory`,
/// `AlertRuleDisplay.swift`) per the redesign spec — previously every rule
/// sat in one flat "Alert Rules" section regardless of what it monitored.
struct AlertsTabView: View {
    @Environment(\.themePalette) private var palette

    /// Local-only display state for the toggles below. Seeded once from
    /// `AppSettings.defaultAlertRules` and never written anywhere — see
    /// `ruleRow`'s doc comment for why a toggle here can't reach the Mac.
    @State private var rules: [AlertRule] = AppSettings.defaultAlertRules

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                title
                ForEach(AlertCategory.allCases) { category in
                    if let indices = groupedIndices[category], !indices.isEmpty {
                        categorySection(category, indices: indices)
                    }
                }
                historyDisclosure
            }
            .padding(palette.spacing * 2)
        }
        .themedScreenBackground(palette)
    }

    // MARK: - Title

    private var title: some View {
        Text("Alerts")
            .font(palette.font(size: 20, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
    }

    // MARK: - Rules, grouped by category

    /// Rule indices (into `rules`, so `ruleRow` can bind back into the
    /// array) grouped by `AlertCategory`, preserving `rules`' own order
    /// within each group — `Dictionary(grouping:by:)` iterates its input in
    /// order and appends, so this doesn't need an explicit sort.
    private var groupedIndices: [AlertCategory: [Int]] {
        Dictionary(grouping: rules.indices) { AlertCategory(module: rules[$0].metric.module) }
    }

    private func categorySection(_ category: AlertCategory, indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: palette.spacing * 0.75) {
            Text(category.displayName.uppercased())
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
            VStack(spacing: 0) {
                ForEach(Array(indices.enumerated()), id: \.element) { position, index in
                    ruleRow($rules[index])
                    if position < indices.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(palette.spacing * 1.2)
            .glassCard(palette)
        }
    }

    /// Plan §12.1 asks for "rule enable/disable"; full rule *editing*
    /// (metric, threshold, actions, preconditions — `AlertsPane`'s
    /// inspector) stays on the Mac. Even the narrower "enable/disable" ask
    /// can't be wired to anything real today, though: making a toggle here
    /// actually flip a rule's `isEnabled` on the Mac needs a live
    /// round-trip — either a synced, editable `AlertRule` record (which
    /// doesn't exist; see this file's top doc comment) or a `ControlCommand`
    /// sent over CloudKit (`SyncRecords.swift`), which needs the same live
    /// container `SyncPane.swift` explains this build doesn't have. The
    /// toggle below is real and interactive (so the list isn't a static,
    /// unreadable wall of text), but it only ever changes local view state
    /// on this iPhone — the accessibility hint says so every time, not just
    /// once at the top of the screen, because a toggle a user just flipped
    /// is the moment they're most likely to assume it did something.
    private func ruleRow(_ rule: Binding<AlertRule>) -> some View {
        HStack(alignment: .center, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.wrappedValue.name)
                    .font(palette.font(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Text(AlertRuleDisplay.conditionSummary(for: rule.wrappedValue))
                    .font(palette.font(size: 10.5))
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: palette.spacing)
            Toggle("", isOn: rule.isEnabled)
                .labelsHidden()
                .tint(palette.accent)
        }
        .padding(.vertical, palette.spacing * 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Local display only — does not change this rule on your Mac")
    }

    // MARK: - History (deliberately an honest gap, not a feed)

    /// See this file's top-level doc comment for why there is no feed to
    /// show. Restyled to the same muted "intentional disclosure" look as
    /// History's `chargeSessionGapNotice` and Settings' sync-status row —
    /// the full explanation moves to an accessibility hint so the visible
    /// row stays short.
    private var historyDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(palette.textTertiary)
                Text("Alert history isn't synced to this iPhone yet")
                    .font(palette.font(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
            }
            Text("Sentry logs fired alerts locally on the Mac — there's no CloudKit record type for alert history yet, so nothing about a firing has ever reached this iPhone.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: palette.cornerRadius)
                .strokeBorder(palette.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("This isn't a per-device setting or something to refresh; there's simply no data path here today.")
    }
}

#Preview {
    AlertsTabView()
}
