import SwiftUI
import MacStatKit

/// Tab 3 — Alerts (plan §12.1: "Recent alert feed, Rule enable/disable
/// (full editing stays on the Mac for v2)").
///
/// **Why the feed half of this tab is an honest empty state, not a feed.**
/// Plan §7.3 lists exactly five CloudKit record types — `Device`,
/// `Snapshot`, `DailyHealth`, `ControlCommand`, `ControlStatus`
/// (`MacStatKit/Sync/SyncRecords.swift`) — and there is no `Alert` or
/// `AlertFiring` record type anywhere in the plan or this codebase. The
/// Mac's fired-alert history (`alert_log`, written by
/// `HistoryStore.logAlertFiring`/read by `HistoryStore.recentAlertFirings`)
/// is local SQLite only; nothing has ever serialized a row of it to
/// CloudKit, so there is no data path by which this iPhone process could
/// know what has fired on the Mac. Inventing a plausible-looking feed here
/// — synthetic timestamps, synthetic rule names — would be exactly the
/// "confident UI describing a reality that isn't true" bug `SyncPane.swift`
/// (`MacStat/Settings/Panes/SyncPane.swift`) was written to stop
/// reintroducing elsewhere in this app; `historySection` below intentionally
/// borrows that pane's direct, non-apologetic tone rather than something
/// softer like "coming soon." Designing the actual sync record type this
/// needs is a real architecture decision for the CloudKit sync work, not a
/// call this tab gets to make on its own.
///
/// **Why the rule list is real content, not a mock.** `AppSettings.defaultAlertRules`
/// (`MacStatKit/Settings/AppSettings.swift`) is the exact 11-rule set
/// `AlertEngine.defaultRules(cooldown:)` builds and MacStat actually ships
/// with — showing it here is reporting a true fact about the Mac app, the
/// same way `SyncPane`'s cadence table shows `SyncService`'s real, tested
/// cadence constants "as documentation, not status." No firing history, no
/// per-Mac customization, and no live rule set are implied by this list —
/// see `ruleRow`'s and `rulesSection`'s doc comments for exactly what the
/// enable/disable toggle does and doesn't do.
struct AlertsTabView: View {

    /// Local-only display state for the toggles below. Seeded once from
    /// `AppSettings.defaultAlertRules` and never written anywhere — see
    /// `rulesSection`'s doc comment for why a toggle here can't reach the
    /// Mac.
    @State private var rules: [AlertRule] = AppSettings.defaultAlertRules

    var body: some View {
        NavigationStack {
            List {
                rulesSection
                historySection
            }
            .navigationTitle("Alerts")
        }
    }

    // MARK: - Rules

    /// Plan §12.1 asks for "rule enable/disable"; full rule *editing*
    /// (metric, threshold, actions, preconditions — `AlertsPane`'s
    /// inspector) stays on the Mac. Even the narrower "enable/disable" ask
    /// can't be wired to anything real today, though: making a toggle here
    /// actually flip a rule's `isEnabled` on the Mac needs a live
    /// round-trip — either a synced, editable `AlertRule` record (which
    /// doesn't exist; see `AlertsTabView`'s top doc comment) or a
    /// `ControlCommand` sent over CloudKit (`SyncRecords.swift`), which
    /// needs the same live container `SyncPane.swift` explains this build
    /// doesn't have. `AppSettings.cloudKitSyncEnabled` sat unexposed in the
    /// Mac's `SyncPane` for exactly this reason — a toggle with no reader
    /// is the "slider that silently does nothing" bug — and this section
    /// follows the same precedent, but chooses the *other* honest option
    /// available to it: the toggles below are real and interactive (so the
    /// list isn't a static, unreadable wall of text), but every one of them
    /// only ever changes local view state on this iPhone. The footer below
    /// says so in the same words every time a toggle is touched, not just
    /// once at the top of the screen, because a toggle a user just flipped
    /// is the moment they're most likely to assume it did something.
    private var rulesSection: some View {
        Section {
            ForEach($rules) { $rule in
                ruleRow($rule)
            }
        } header: {
            Text("Alert Rules")
        } footer: {
            Text("These are the 11 alert rules MacStat ships with by default. Switching one here only changes what this iPhone shows — there's no live connection to your Mac yet, so it doesn't enable, disable, or otherwise change anything running there. Full rule editing stays on the Mac.")
        }
    }

    private func ruleRow(_ rule: Binding<AlertRule>) -> some View {
        Toggle(isOn: rule.isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.wrappedValue.name)
                Text(AlertRuleDisplay.conditionSummary(for: rule.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Local display only — does not change this rule on your Mac")
    }

    // MARK: - History

    /// See this file's top-level doc comment for why there is no feed to
    /// show. Matches `SyncPane`'s "Status" section in structure — an icon
    /// + a short, direct sentence explaining a true, permanent-for-this-
    /// build fact, not a per-user condition to troubleshoot.
    private var historySection: some View {
        Section {
            Label {
                Text("Alert history isn't synced to this iPhone yet")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "bell.slash")
                    .foregroundStyle(.secondary)
            }

            Text("MacStat logs fired alerts on the Mac (in \u{201c}alert_log\u{201d}), but that log is local to the Mac's own database — there's no CloudKit record type for alert history yet, so nothing about a firing has ever reached this iPhone. This isn't a per-device setting or something to refresh; there's simply no data path here today.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Alert History")
        }
    }
}

#Preview {
    AlertsTabView()
}
