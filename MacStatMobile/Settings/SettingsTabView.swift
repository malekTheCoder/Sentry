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
/// (`MacStatKit/Settings/Theme.swift`) is the exact same set of presets the
/// Mac app ships, and selecting one here actually re-themes all four tabs —
/// see `RootTabView`'s doc comment for how the selection propagates via
/// `@AppStorage` + `.environment(\.themePalette:)`. This is a genuine,
/// working, "shares Theme tokens with the Mac app" feature.
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
///
/// **Nocturne redesign restyle.** Was a native `Form`/`Section` screen (the
/// theme picker was a `.pickerStyle(.navigationLink)` row into a full
/// sub-screen, not a preview-able swatch). Rebuilt as a themed `ScrollView`
/// matching the other three tabs: a horizontally scrollable row of 44×44pt
/// theme swatches (each rendering *that* theme's own colors, not the
/// ambient one, so tapping through actually previews before committing), a
/// compact paired-device card, and the honest-disclosure pattern shared
/// with History's charge-session row and Alerts' history row for the
/// sections that don't do anything real yet.
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

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    /// The one mock Mac this build has anything to say about. Built directly
    /// here rather than threaded through a view model — this tab makes
    /// exactly one read (`mockDevice`, a `let` property `MockDataSource`
    /// exposes for synchronous, un-awaited access per SE-0313; see that
    /// type's `snapshots()` doc comment for the same reasoning) and needs no
    /// ongoing snapshot subscription the way `DashboardViewModel` does.
    private let dataSource = MockDataSource()

    private var device: Device { dataSource.mockDevice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                title
                themeSection
                deviceCard
                syncStatusRow
                notificationsSection
                widgetsSection
            }
            .padding(palette.spacing * 2)
        }
        .background(palette.background)
    }

    // MARK: - Title

    private var title: some View {
        Text("Settings")
            .font(palette.font(size: 20, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
    }

    // MARK: - Theme (the real, working section)

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: palette.spacing * 0.75) {
            Text("THEME")
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: palette.spacing) {
                    ForEach(Theme.builtInPresets) { theme in
                        themeSwatch(theme)
                    }
                }
                .padding(.vertical, 2)
            }
            Text("The same presets as the Mac app (MacStatKit/Settings/Theme.swift), applied to all four tabs. This is a local preference, not synced — there's no iCloud channel yet to carry it to or from the Mac, so choosing a theme here has no effect on the Mac app and vice versa.")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
        }
    }

    /// One 44×44pt rounded swatch per built-in preset (9px corner radius,
    /// per the redesign spec), tappable to apply. Deliberately renders
    /// *that* theme's own `background`/`separator` colors rather than the
    /// ambient `palette` — the point of a swatch picker is previewing the
    /// themes you're not currently using, so reusing the injected
    /// `ThemePalette` here would make every swatch look identical.
    private func themeSwatch(_ theme: Theme) -> some View {
        let isSelected = theme.id == selectedThemeID
        let background = theme.background.color(for: colorScheme)
        let border = theme.separator.color(for: colorScheme)
        let accent = theme.accent.color(for: colorScheme)
        return Button {
            selectedThemeID = theme.id
        } label: {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(background)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isSelected ? accent : border, lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Paired device (mock data, honestly labeled)

    /// Plan §12.1's "Devices" half. Two-line card (name + meta caption) per
    /// the redesign spec's shape. The spec's literal mock text for the meta
    /// line is "Paired · Last synced 2m ago" — not used verbatim here,
    /// deliberately: this build has no sync channel at all (see
    /// `syncStatusRow` right below this card), and every other honesty
    /// discipline in this codebase (`SyncPane.swift`, `demoDataBanner` on
    /// Dashboard/History, this same file's own doc comment) exists
    /// specifically to stop a screen from claiming a sync event that never
    /// happened. Showing "Last synced 2m ago" one card above "iCloud sync
    /// isn't available in this build yet" would be a direct, visible
    /// self-contradiction on the same screen. The meta line instead reports
    /// the one true thing this build knows about the device (its model)
    /// plus the honest state, keeping the intended two-line visual shape
    /// without inventing a sync timestamp.
    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(device.deviceName)
                .font(palette.font(size: 12.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Text("\(device.model) · Demo device, not synced")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("This is demo data from MockDataSource, not a real Mac — there is no Mac on the other end reporting in.")
    }

    // MARK: - Sync status (SyncPane's tone, mobile side)

    /// The iPhone-side counterpart of `MacStat/Settings/Panes/SyncPane.swift`.
    /// Deliberately mirrors that pane's wording and its list of banned
    /// phrasings ("Connected," "Syncing," "Up to date," a spinner, a
    /// fabricated record count) rather than inventing new language for the
    /// same underlying fact: this build has no iCloud container, no
    /// `CKContainer`, no push subscription, on either platform, for the same
    /// reason (`MacStat` isn't enrolled in the Apple Developer Program).
    /// Same muted "honest disclosure" row style as History's
    /// `chargeSessionGapNotice` and Alerts' `historyDisclosure` — a small
    /// outlined circle + one line of tertiary text, full explanation in the
    /// accessibility hint.
    private var syncStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(palette.textTertiary)
            Text("iCloud sync isn't available in this build yet.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("MacStat isn't enrolled in the Apple Developer Program yet, so this phone has no iCloud container to sync through — no account, no server, no network connection. Nothing has ever synced to or from a real Mac.")
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
    /// so it can't drift out of sync with the Mac app's actual default
    /// rules — as plain, non-interactive reference text.
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: palette.spacing * 0.75) {
            Text("NOTIFICATION CATEGORIES")
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.notificationCategoryNames, id: \.self) { name in
                    Text(name)
                        .font(palette.font(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            Text("These mirror the Mac app's alert rules (AlertRule/AlertAction, MacStatKit/Services/AlertRule.swift) — shown for reference, not as working preferences. Notifications require a live sync connection this build doesn't have, so there's nothing here to turn on or off yet.")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
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
    /// outright, same muted honest-disclosure row style as the sections
    /// above it.
    private var widgetsSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(palette.textTertiary)
            Text("Widgets aren't available in this build yet.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("MacStatWidget is still the unconfigured Xcode template it started as — a single static placeholder, no data pipeline, no App Group shared with this app.")
    }
}
