import SwiftUI
import MacStatKit

// MARK: - SettingsTabView (plan §12.1)

/// Tab 4 — Settings. Plan §12.1 lists four things for this tab: "Devices &
/// sync status, Notification preferences, Widget configuration, Theme
/// (shares Theme tokens with the Mac app)." Of those four, exactly one is
/// buildable as a real, working feature today — the rest describe surfaces
/// for infrastructure that doesn't exist in this build (see each section's
/// doc comment below for specifics). This file follows the same honesty
/// discipline `MacStat/Settings/Panes/SyncPane.swift` established on the Mac
/// side: say plainly what doesn't work and why, rather than hiding it behind
/// "coming soon" or — worse — a control that looks functional but silently
/// does nothing (`SyncPane`'s doc comment calls this codebase's canonical
/// prior bug by name: "a settings slider that silently did nothing").
///
/// **What's real: the theme picker.** `Theme.builtInPresets`
/// (`MacStatKit/Settings/Theme.swift`) is the exact same six presets the Mac
/// app ships, and selecting one here actually re-themes all four tabs — see
/// `RootTabView`'s doc comment for how the selection propagates via
/// `@AppStorage` + `.environment(\.themePalette:)`. This is a genuine,
/// working, "shares Theme tokens with the Mac app" feature, which is why
/// it's the only section below written like a normal preferences screen
/// rather than a disclosure.
///
/// **What's honest-but-inert: devices & sync, notifications, widgets.** Each
/// is gated on the same missing piece — no enrolled Apple Developer Program
/// account, therefore no CloudKit container, therefore no push
/// infrastructure, therefore no real device catalog and no way to schedule a
/// local notification that means anything (a notification with no upstream
/// event to trigger it isn't a notification *preference*, it's dead UI).
/// Rather than three near-identical "not available yet" screens, each
/// section says specifically what's missing and what's shown instead (mock
/// data, static rule names, a stub file), so a reader can tell these apart
/// from three genuinely different kinds of "not done."
struct SettingsTabView: View {
    /// Backs the theme picker below. Default matches `Theme.terminal.id` —
    /// the same default `AppSettings.themeID` uses on the Mac side
    /// (`MacStatKit/Settings/AppSettings.swift`) — so a phone that has never
    /// had this key written resolves to the same theme the Mac ships with,
    /// rather than an arbitrary first-in-array preset.
    ///
    /// This is a *separate* `@AppStorage` property from `RootTabView`'s, not
    /// a binding passed down — see `RootTabView`'s doc comment for why the
    /// string key (not a shared Swift symbol) is what actually keeps them in
    /// sync, and why that's an accepted duplication rather than an oversight.
    @AppStorage("selectedThemeID") private var selectedThemeID: String = Theme.terminal.id

    /// The one mock Mac this build has anything to say about. Built directly
    /// here rather than threaded through a view model — this tab makes
    /// exactly one read (`mockDevice`, a `let` property `MockDataSource`
    /// exposes for synchronous, un-awaited access per SE-0313; see that
    /// type's `snapshots()` doc comment for the same reasoning) and needs no
    /// ongoing snapshot subscription the way `DashboardViewModel` does.
    private let dataSource = MockDataSource()

    private var device: Device { dataSource.mockDevice }

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                devicesSection
                syncStatusSection
                notificationsSection
                widgetsSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Theme (the real, working section)

    private var themeSection: some View {
        Section {
            Picker("Theme", selection: $selectedThemeID) {
                ForEach(Theme.builtInPresets) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Theme")
        } footer: {
            Text("The same six presets as the Mac app (MacStatKit/Settings/Theme.swift), applied to all four tabs on this phone. This is a local preference, not synced — there's no iCloud channel yet to carry it to or from the Mac, so choosing a theme here has no effect on the Mac app and vice versa.")
        }
    }

    // MARK: - Devices (mock data, clearly labeled)

    /// Plan §12.1's "Devices" half. Renders the one `Device` this build can
    /// ever produce, through the exact same `FreshnessBadge`/`Freshness`
    /// pipeline `DashboardTabView.freshnessBanner` uses — per
    /// `MockDataSource`'s own doc comment, no screen is allowed to
    /// special-case the mock device out of that discipline, this one
    /// included.
    private var devicesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.deviceName)
                    .font(.headline)
                Text(device.model)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(device.chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(device.osVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            FreshnessBadge(lastSeen: device.lastSeen)
        } header: {
            Text("Devices")
        } footer: {
            Text("This is demo data from MockDataSource, not a real Mac (see that type's doc comment) — there is no Mac on the other end reporting in. Adding or removing a Mac isn't possible in this build: there is only ever this one mock device, and the list never changes.")
        }
    }

    // MARK: - Sync status (SyncPane's tone, mobile side)

    /// The iPhone-side counterpart of `MacStat/Settings/Panes/SyncPane.swift`.
    /// Deliberately mirrors that pane's wording and its list of banned
    /// phrasings ("Connected," "Syncing," "Up to date," a spinner, a
    /// fabricated record count) rather than inventing new language for the
    /// same underlying fact: this build has no iCloud container, no
    /// `CKContainer`, no push subscription, on either platform, for the same
    /// reason (`MacStat` isn't enrolled in the Apple Developer Program).
    private var syncStatusSection: some View {
        Section {
            Label {
                Text("iCloud sync isn't available in this build")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
            }

            Text("MacStat isn't enrolled in the Apple Developer Program yet, so this phone has no iCloud container to sync through — no account, no server, no network connection. Nothing has ever synced to or from a real Mac, and nothing is attempting to. This isn't a per-device setting or a bug to troubleshoot; it's true for every copy of this build.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Sync Status")
        }
    }

    // MARK: - Notifications (informational only — no working preferences)

    /// Plan §12.1 wants "Notification preferences" here, but a preference
    /// only means something if it changes what happens later — and nothing
    /// can deliver a push notification in this build (no CloudKit
    /// subscription, no APNs registration; `AlertAction.pushToPhone`,
    /// `MacStatKit/Services/AlertRule.swift`, is a documented no-op on the
    /// Mac side for the identical reason). Building toggles that don't wire
    /// to anything would recreate the exact "slider that silently does
    /// nothing" bug `SyncPane`'s doc comment names as this codebase's own
    /// prior mistake. Instead this section lists the categories a real
    /// build *would* notify about — read directly from
    /// `AlertEngine.defaultRules(cooldown:)` rather than a hand-copied list,
    /// so it can't drift out of sync with the Mac app's actual 11 default
    /// rules — as plain, non-interactive reference text.
    private var notificationsSection: some View {
        Section {
            ForEach(Self.notificationCategoryNames, id: \.self) { name in
                Text(name)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Notification Categories")
        } footer: {
            Text("These mirror the Mac app's alert rules (AlertRule/AlertAction, MacStatKit/Services/AlertRule.swift) — shown for reference, not as working preferences. Notifications require a live sync connection this build doesn't have, so there's nothing here to turn on or off yet.")
        }
    }

    /// `cooldown` is irrelevant to the names themselves (it only affects
    /// each rule's `cooldown` field) — `0` is passed purely because
    /// `defaultRules(cooldown:)` requires an argument; no rule's name
    /// depends on it.
    private static let notificationCategoryNames: [String] =
        AlertEngine.defaultRules(cooldown: 0).map(\.name)

    // MARK: - Widgets (nothing built yet, said plainly)

    /// Plan §12.3/Phase 6 territory. `MacStatWidget/MacStatWidgetBundle.swift`
    /// today is an unmodified Xcode template: a `TimelineProvider` that
    /// always returns the same placeholder entry, and an entry view that
    /// renders the literal text "MacStat" — no App Group, no shared
    /// container, no real timeline data, nothing connecting it to
    /// `MacStatKit` at all. There is no widget configuration surface to
    /// build against, so this section doesn't invent one (e.g. a fake "which
    /// metrics to show" picker with nothing behind it) — it says the gap
    /// outright, the same "labeled stub beats fabricated UI" reasoning
    /// `DashboardTabView.PlaceholderCard`'s doc comment already establishes
    /// for this codebase.
    private var widgetsSection: some View {
        Section {
            Label {
                Text("Widgets aren't available in this build yet")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "square.dashed")
                    .foregroundStyle(.secondary)
            }

            Text("MacStatWidget is still the unconfigured Xcode template it started as — a single static placeholder, no data pipeline, no App Group shared with this app. There's nothing to configure yet, so this section doesn't offer options that wouldn't do anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Widgets")
        }
    }
}
