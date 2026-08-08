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
                readOnlyNotice
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
            .scaledFont(palette, size: 20, weight: .semibold)
            .foregroundStyle(palette.textPrimary)
    }

    /// **Connection-honesty review, bug #4.** Every rule below used to carry
    /// a real, animating `Toggle` that changed local `@State`, persisted
    /// nothing, and never reached the Mac — the exact "settings slider that
    /// silently does nothing" anti-pattern `SettingsTabView`'s doc comment
    /// (quoting `SyncPane.swift`) names as this codebase's own canonical
    /// prior bug. Real two-way sync needs Mac-side wiring (a synced,
    /// editable `AlertRule` record or a `ControlCommand` round-trip — see
    /// this file's top doc comment) that's out of scope here. Until that
    /// exists, this one-line notice sits above the list so the read-only
    /// nature is established before a user reaches for the first switch,
    /// not discovered by flipping one and wondering why nothing happened.
    private var readOnlyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .scaledSystemFont(size: 9)
                .foregroundStyle(palette.textTertiary)
            Text("Read-only preview of your Mac's alert rules — switches here don't change anything yet.")
                .scaledFont(palette, size: 11)
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Rule editing stays on the Mac. These rows show each rule's current enabled state for reference; the switches are disabled because there is no live connection this tab can send a change through yet.")
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
                .scaledFont(palette, size: 10, weight: .semibold)
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
    /// container `SyncPane.swift` explains this build doesn't have.
    ///
    /// **Disabled, not animating (connection-honesty review, bug #4).** This
    /// `Toggle` used to be fully interactive — it flipped, animated, and
    /// changed local `@State`, giving every visual signal of doing something
    /// real while persisting nothing and reaching the Mac never. That is
    /// this codebase's own named anti-pattern (`SyncPane.swift`'s "a
    /// settings slider that silently does nothing," quoted in
    /// `SettingsTabView`'s doc comment). It's `.disabled(true)` now — still
    /// showing each rule's real enabled/disabled state at a glance (a
    /// disabled `Toggle` still renders its bound value), just not offering a
    /// tap that goes nowhere. `readOnlyNotice` above states the read-only
    /// reason once, up front; this row's hint restates it locally too, since
    /// a toggle someone just tapped (and felt not move) is the moment
    /// they're most likely to look for an explanation.
    ///
    /// **And therefore no haptic, which is the correct answer rather than an
    /// omission.** Arming and disarming a rule is `SentryHaptic.begin`/`.end`
    /// — that case's own doc comment names "arming a rule" as an example. But
    /// the feedback in this app is attached to state that changed, and this
    /// switch cannot change: it is `.disabled(true)` because there is no
    /// channel to carry the change to the Mac. A buzz here would be the
    /// haptic edition of the same lie the disabled state exists to stop —
    /// telling the user's thumb that something was armed when nothing was.
    /// The day a real round trip exists, this row wants the same two-beat
    /// treatment `SleepStatusCard` uses (`.begin`/`.end` on the tap,
    /// `.confirmed`/`.rejected` on the Mac's reply), not a haptic on the
    /// local `@State` flip.
    private func ruleRow(_ rule: Binding<AlertRule>) -> some View {
        // A `Toggle` has a fixed ~51pt intrinsic width that never shrinks, so
        // at accessibility sizes the rule name and its condition summary get
        // whatever is left and start wrapping to one word a line. Stacking
        // gives the text the full row width and puts the switch on its own
        // line underneath, still inside the same combined accessibility
        // element.
        AdaptiveRow(spacing: palette.spacing, verticalAlignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.wrappedValue.name)
                    .scaledFont(palette, size: 12.5, weight: .medium)
                    .foregroundStyle(palette.textPrimary)
                Text(AlertRuleDisplay.conditionSummary(for: rule.wrappedValue))
                    .scaledFont(palette, size: 10.5)
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } trailing: {
            Toggle("", isOn: rule.isEnabled)
                .labelsHidden()
                .tint(palette.accent)
                .disabled(true)
        }
        .padding(.vertical, palette.spacing * 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Read-only preview of this rule's state on your Mac — does not change this rule.")
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
                    .scaledFont(palette, size: 12, weight: .semibold)
                    .foregroundStyle(palette.textSecondary)
            }
            Text("Sentry logs fired alerts locally on the Mac — there's no CloudKit record type for alert history yet, so nothing about a firing has ever reached this iPhone.")
                .scaledFont(palette, size: 11)
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
