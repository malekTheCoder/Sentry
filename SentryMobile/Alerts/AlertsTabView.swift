import SwiftUI
import SentryKit

/// Tab 3 — Alerts (plan §12.1: "Recent alert feed, Rule enable/disable
/// (full editing stays on the Mac for v2)").
///
/// **Why this tab has no fired-alert feed.** The Mac's fired-alert history
/// (`alert_log`, written by `HistoryStore.logAlertFiring`/read by
/// `HistoryStore.recentAlertFirings`) is local SQLite only, and the
/// LocalSync wire (`LocalSyncFraming`) carries snapshots, commands, and
/// statuses — no alert-firing record type exists anywhere in this codebase,
/// so there is no data path by which this iPhone process could know what
/// has fired on the Mac. Inventing a plausible-looking feed here —
/// synthetic timestamps, synthetic rule names — would be exactly the
/// "confident UI describing a reality that isn't true" bug this codebase's
/// honesty discipline exists to stop. And a card *explaining* the absence
/// is clutter of its own (an earlier revision shipped one): a section whose
/// only content is that it has no content tells the user nothing they can
/// act on, so this tab simply doesn't have a history section. Designing the
/// actual sync record type this needs is a real architecture decision for
/// the device sync work, not a call this tab gets to make on its own.
///
/// **Why the rule list is real content, not a mock.** `AppSettings.defaultAlertRules`
/// (`SentryKit/Settings/AppSettings.swift`) is the exact 11-rule set
/// `AlertEngine.defaultRules(cooldown:)` builds and Sentry actually ships
/// with — showing it here is reporting a true fact about the Mac app,
/// as documentation, not status. No firing history, no
/// per-Mac customization, and no live rule set are implied by this list —
/// see `ruleRow`'s doc comment for how each rule's enabled state is
/// presented and why it is not a switch.
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

    /// The shipped default rule set, presented read-only. A plain `let`,
    /// not `@State`: nothing on this tab can change a rule (see `ruleRow`),
    /// so there is no state to hold.
    private let rules: [AlertRule] = AppSettings.defaultAlertRules

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                title
                caption
                ForEach(AlertCategory.allCases) { category in
                    if let categoryRules = groupedRules[category], !categoryRules.isEmpty {
                        categorySection(category, rules: categoryRules)
                    }
                }
            }
            .padding(palette.spacing * 2)
        }
        .themedScreenBackground(palette)
    }

    // MARK: - Title

    private var title: some View {
        Text("Alerts")
            .scaledFont(palette, size: 20, weight: .semibold)
            .foregroundStyle(palette.textPrimary)
    }

    /// One line of context for the list below: whose rules these are, and
    /// where editing lives. Describes what the list *is* — it replaced an
    /// earlier disclaimer about switches that didn't do anything, which
    /// left with the switches themselves (see `ruleRow`).
    private var caption: some View {
        Text("The alert rules the Mac app ships with — rule editing stays on the Mac.")
            .scaledFont(palette, size: 11)
            .foregroundStyle(palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Rules, grouped by category

    /// Rules grouped by `AlertCategory`, preserving `rules`' own order
    /// within each group — `Dictionary(grouping:by:)` iterates its input in
    /// order and appends, so this doesn't need an explicit sort.
    private var groupedRules: [AlertCategory: [AlertRule]] {
        Dictionary(grouping: rules) { AlertCategory(module: $0.metric.module) }
    }

    private func categorySection(_ category: AlertCategory, rules: [AlertRule]) -> some View {
        VStack(alignment: .leading, spacing: palette.spacing * 0.75) {
            Text(category.displayName.uppercased())
                .scaledFont(palette, size: 10, weight: .semibold)
                .foregroundStyle(palette.textTertiary)
            VStack(spacing: 0) {
                ForEach(Array(rules.enumerated()), id: \.element.id) { position, rule in
                    ruleRow(rule)
                    if position < rules.count - 1 {
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
    /// inspector) stays on the Mac, and even the narrower enable/disable
    /// can't be wired to anything real today: making a control here
    /// actually flip a rule's `isEnabled` on the Mac needs a live
    /// round-trip — either a synced, editable `AlertRule` record (which
    /// doesn't exist; see this file's top doc comment) or a dedicated
    /// rule-edit `ControlCommand` type, which `LocalCommandExecutor`
    /// doesn't define.
    ///
    /// **A state capsule, not a switch.** Earlier revisions rendered a
    /// `Toggle` here — first fully interactive (flipped local `@State`,
    /// persisted nothing, reached the Mac never: this codebase's canonical
    /// "settings slider that silently does nothing" anti-pattern), then
    /// `.disabled(true)` under an apologetic notice. A disabled switch is
    /// still shaped like the control it isn't, which is why it needed a
    /// disclaimer to explain itself. The capsule states the same fact —
    /// this rule ships on, this rule ships off — in a form that never
    /// claims to be tappable, so nothing needs disclaiming. Styled after
    /// `DemoDataTag` (`SentryMobile/Disclosure/DemoDataBanner.swift`), the
    /// app's existing tiny-status-capsule vocabulary, at roughly the visual
    /// weight the switch occupied. The day a real round-trip exists, this
    /// row wants a real `Toggle` with `SleepStatusCard`'s two-beat haptic
    /// treatment (`.begin`/`.end` on the tap, `.confirmed`/`.rejected` on
    /// the Mac's reply) — not this capsule made tappable.
    ///
    /// VoiceOver reads the row as "name, condition, on/off" — a value, not
    /// a toggle: the capsule's own uppercased text is hidden and restated
    /// through `accessibilityValue`, so nothing announces a switch that
    /// can't be flipped.
    private func ruleRow(_ rule: AlertRule) -> some View {
        // At accessibility sizes the rule name and its condition summary
        // need the full row width to avoid wrapping to one word a line.
        // Stacking gives the text the whole row and puts the state capsule
        // on its own line underneath, still inside the same combined
        // accessibility element.
        AdaptiveRow(spacing: palette.spacing, verticalAlignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .scaledFont(palette, size: 12.5, weight: .medium)
                    .foregroundStyle(palette.textPrimary)
                Text(AlertRuleDisplay.conditionSummary(for: rule))
                    .scaledFont(palette, size: 10.5)
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } trailing: {
            stateCapsule(isEnabled: rule.isEnabled)
        }
        .padding(.vertical, palette.spacing * 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(rule.isEnabled ? Text("On") : Text("Off"))
    }

    /// The row's trailing state readout — see `ruleRow` for why this is
    /// not a `Toggle`. Same capsule vocabulary as `DemoDataTag`: a tiny
    /// uppercased label in a tinted capsule, enough weight to scan down
    /// the list, none of a control's affordance. Accent-on-accent-wash for
    /// on, tertiary-on-elevated-surface for off, all from `palette` so the
    /// pair reads as two states of one thing in every theme.
    private func stateCapsule(isEnabled: Bool) -> some View {
        Text(isEnabled ? String(localized: "On").uppercased() : String(localized: "Off").uppercased())
            .scaledFont(palette, size: 9, weight: .semibold)
            .kerning(0.6)
            .foregroundStyle(isEnabled ? palette.accent : palette.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isEnabled ? palette.accent.opacity(0.14) : palette.surfaceElevated)
            )
            .accessibilityHidden(true)
    }
}

#Preview {
    AlertsTabView()
}
