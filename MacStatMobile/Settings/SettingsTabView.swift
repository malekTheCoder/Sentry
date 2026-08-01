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
    /// Backs the theme picker below. Default matches `Theme.defaultTheme.id` —
    /// the same default `AppSettings.themeID` uses on the Mac side
    /// (`MacStatKit/Settings/AppSettings.swift`) — so a phone that has never
    /// had this key written resolves to the same theme the Mac ships with,
    /// rather than an arbitrary first-in-array preset.
    ///
    /// This is a *separate* `@AppStorage` property from `RootTabView`'s, not
    /// a binding passed down — see `RootTabView`'s doc comment for why the
    /// string key (not a shared Swift symbol) is what actually keeps them in
    /// sync, and why that's an accepted duplication rather than an oversight.
    @AppStorage("selectedThemeID") private var selectedThemeID: String = Theme.oneDark.id

    /// The remote-Mac fallback endpoint — see `remoteMacSection`. The keys
    /// must match `AppDataSource.remoteEndpointFromDefaults()` exactly.
    @AppStorage("remoteSync.host") private var remoteHost: String = ""
    @AppStorage("remoteSync.port") private var remotePort: String = "8643"
    @AppStorage("remoteSync.code") private var remoteCode: String = ""

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    /// Reads from the app-wide `AppDataSource.shared`
    /// (`MacStatMobile/Data/AppDataSource.swift`) instead of constructing
    /// its own `MockDataSource()` — this tab used to make exactly one
    /// synchronous read (`MockDataSource.mockDevice`) and needed no ongoing
    /// snapshot subscription, but that shortcut only worked because
    /// `MockDataSource` is stateless and cheap to duplicate. A real
    /// `LocalSyncClient` behind `AppDataSource` is neither, so this tab now
    /// asks the shared instance for its device catalog like every other
    /// consumer, via `.task`/`AppDataSource.devices()` populating `device`
    /// below rather than a synchronous property read.
    @EnvironmentObject private var appDataSource: AppDataSource

    @State private var device: Device?

    /// Drives `locationLogSection` below — see `LocationLogViewModel`'s doc
    /// comment for why this follows `AppDataSource.shared`'s snapshot stream
    /// independently of `DashboardViewModel` rather than sharing that view
    /// model's `latestSnapshot`.
    @StateObject private var locationLogViewModel = LocationLogViewModel()

    /// Falls back to `MockDataSource`'s own fixed mock device whenever
    /// nothing has loaded yet (first frame, before `.task` below has run) —
    /// keeps this section rendering something plausible immediately, same
    /// as `AppDataSource.transport`'s own "start as a mock, not nil"
    /// default.
    private var displayedDevice: Device {
        device ?? MockDataSource().mockDevice
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                title
                themeSection
                deviceCard
                syncStatusRow
                remoteMacSection
                LocationLogSection(viewModel: locationLogViewModel)
                notificationsSection
                widgetsSection
            }
            .padding(palette.spacing * 2)
        }
        .themedScreenBackground(palette)
        .task {
            device = await appDataSource.devices().first
        }
    }

    // MARK: - Title

    private var title: some View {
        Text("Settings")
            .font(palette.font(size: 20, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
    }

    // MARK: - Remote Mac (off-LAN connection)

    /// Mirrors the Mac's Settings ▸ Sync ▸ Remote Access: the Mac's
    /// address (its Tailscale/VPN hostname or public address), the port,
    /// and the pairing code shown on the Mac. Read by `AppDataSource` at
    /// launch as the fallback when Bonjour finds nothing on this network.
    /// Stored on this phone only.
    private var remoteMacSection: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            Text("REMOTE MAC")
                .font(palette.font(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: palette.spacingRow) {
                TextField("Address (e.g. my-mac.tailnet.ts.net)", text: $remoteHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", text: $remotePort)
                    .keyboardType(.numberPad)
                TextField("Pairing code (from the Mac's Sync settings)", text: $remoteCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            .textFieldStyle(.roundedBorder)

            Text("Lets this phone reach your Mac when it isn't on the same Wi-Fi. Enable Remote Access on the Mac (Settings ▸ Sync), then enter its address, port, and pairing code here. The connection is encrypted and takes effect the next time the app connects — leave the address empty to use local discovery only.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
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
            Text(displayedDevice.deviceName)
                .font(palette.font(size: 12.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            // The meta line's second half distinguishes a real local-network
            // connection from `MockDataSource`'s demo data — `syncStatusRow`
            // right below is scoped specifically to iCloud/CloudKit sync
            // (still genuinely unavailable), not this local-network path, so
            // this is the one place on this tab that actually reflects
            // `AppDataSource.isUsingLocalSync`.
            Text("\(displayedDevice.model) · \(appDataSource.isUsingLocalSync ? "Live on your local network" : "Demo device, not synced")")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            appDataSource.isUsingLocalSync
                ? "This device is live data from a Mac reporting in over your local Wi-Fi network."
                : "This is demo data from MockDataSource, not a real Mac — there is no Mac on the other end reporting in."
        )
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
        .accessibilityHint("Sentry isn't enrolled in the Apple Developer Program yet, so this phone has no iCloud container to sync through — no account, no server, no network connection. Nothing has ever synced through iCloud to or from a real Mac.")
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

    // MARK: - Widgets (real widget, no in-app configuration yet)

    /// The widget itself is real now — `MacStatWidget` renders whatever
    /// `WidgetSnapshotWriter` (`MacStatMobile/Data/WidgetSnapshotWriter.swift`)
    /// last cached through the App Group, on `WidgetTimelineScheduler`'s
    /// reload cadence. What still doesn't exist is any *configuration*
    /// surface (which metrics to show, per-family options) — so this
    /// section describes the one true limitation rather than inventing a
    /// fake picker, same honest-disclosure row style as the sections above.
    /// (This row used to claim "Widgets aren't available in this build yet"
    /// — true when written, stale once the widget pipeline landed.)
    private var widgetsSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(palette.textTertiary)
            Text("Widgets show the Dashboard's latest reading — nothing to configure here yet.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Add the widget from your home screen. It shows the most recent data this app cached — there are no in-app widget options to change yet.")
    }
}
