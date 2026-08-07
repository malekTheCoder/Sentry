import SwiftUI
import SentryKit

// MARK: - SettingsTabView (plan §12.1)

/// Tab 4 — Settings. Plan §12.1 lists four things for this tab: "Devices &
/// sync status, Notification preferences, Widget configuration, Theme
/// (shares Theme tokens with the Mac app)." Of those four, exactly one is
/// buildable as a real, working feature today — the rest describe surfaces
/// for infrastructure that doesn't exist in this build (see each section's
/// doc comment below for specifics). This file follows the same honesty
/// discipline `Sentry/Settings/Panes/SyncPane.swift` established on the Mac
/// side: say plainly what doesn't work and why, rather than hiding it behind
/// "coming soon" or — worse — a control that looks functional but silently
/// does nothing (`SyncPane`'s doc comment calls this codebase's canonical
/// prior bug by name: "a settings slider that silently did nothing").
///
/// **What's real: the theme picker.** `Theme.builtInPresets`
/// (`SentryKit/Settings/Theme.swift`) is the exact same set of presets the
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
    /// (`SentryKit/Settings/AppSettings.swift`) — so a phone that has never
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
    /// Cleared by `walkthroughRow` to re-arm `SentryMobileApp`'s
    /// `fullScreenCover` — see that row's doc comment for why re-arming the
    /// one existing presentation beats presenting a second copy from here,
    /// and for why duplicating the key is the same accepted tradeoff as
    /// `selectedThemeID` above.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @AppStorage("remoteSync.host") private var remoteHost: String = ""
    @AppStorage("remoteSync.port") private var remotePort: String = "8643"
    @AppStorage("remoteSync.code") private var remoteCode: String = ""

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    /// Reads from the app-wide `AppDataSource.shared`
    /// (`SentryMobile/Data/AppDataSource.swift`) instead of constructing
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

    /// Drives the About sheet (`AboutView`). A sheet rather than a pushed
    /// screen because this tab has no `NavigationStack` — see `AboutView`'s
    /// doc comment.
    @State private var showsAbout = false

    /// Which "Remote Mac" field currently has keyboard focus, if any — lets
    /// the numeric-pad "Done" button (bug #5, connection-honesty review)
    /// dismiss the keyboard without a return key, and lets the "Connect"
    /// button below dismiss it before dialing.
    private enum RemoteMacField: Hashable { case host, port, code }
    @FocusState private var focusedRemoteMacField: RemoteMacField?

    /// True while `applyRemoteSettingsFromDefaults()` is in flight — the
    /// "Connect" button shows a spinner in place of its label so a tap that
    /// takes up to `AppDataSource.discoveryTimeout` seconds to resolve
    /// doesn't look like it did nothing.
    @State private var isConnectingRemote = false

    /// Set after a "Connect" tap resolves — `nil` means "hasn't been tried
    /// this session," not "failed," so the row doesn't open with a stale
    /// error before the user has done anything.
    @State private var remoteConnectResult: String?

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
                macPickerSection
                syncStatusRow
                remoteMacSection
                LocationLogSection(viewModel: locationLogViewModel)
                notificationsSection
                widgetsSection
                walkthroughRow
                aboutRow
            }
            .padding(palette.spacing * 2)
        }
        // Bug #5 (connection-honesty review): the port field's
        // `.keyboardType(.numberPad)` has no return key at all, and this
        // `ScrollView` had no way to dismiss the keyboard by scrolling
        // either — once it was up, the only way down was tapping a
        // non-text-field part of the screen. `.interactively` lets a drag
        // on the scroll view itself follow the keyboard down, same gesture
        // Messages/Mail use.
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // Scoped to the numeric field specifically, per the review note
            // — the host/code fields are ordinary text fields a user can
            // already dismiss via the return-key-less-but-scrollable path
            // above, but the number pad has no return key at all, so it
            // needs an explicit way out.
            if focusedRemoteMacField == .port {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedRemoteMacField = nil }
                }
            }
        }
        .sheet(isPresented: $showsAbout) {
            // The palette is re-injected explicitly: a sheet is presented
            // from a separate window scene, and relying on it inheriting
            // `\.themePalette` would leave the sheet on the environment's
            // default theme if that ever changes.
            AboutView().environment(\.themePalette, palette)
        }
        .task {
            device = await appDataSource.devices().first
        }
    }

    // MARK: - Title

    private var title: some View {
        Text("Settings")
            .scaledFont(palette, size: 20, weight: .semibold)
            .foregroundStyle(palette.textPrimary)
    }

    // MARK: - Remote Mac (off-LAN connection)

    /// Mirrors the Mac's Settings ▸ Sync ▸ Remote Access: the Mac's
    /// address (its Tailscale/VPN hostname or public address), the port,
    /// and the pairing code shown on the Mac. Read by `AppDataSource` at
    /// launch as the fallback when Bonjour finds nothing on this network.
    /// Stored on this phone only.
    ///
    /// **The "Connect" button (bug #3, connection-honesty review).** These
    /// fields used to be write-only from this screen's point of view: they
    /// wrote to `@AppStorage`, which `AppDataSource.remoteEndpointFromDefaults()`
    /// only ever reads once, at launch. Typing a corrected hostname after a
    /// typo did nothing until the whole app relaunched — even though the
    /// help text below promised the change "takes effect the next time the
    /// app connects." It does now, but only once something actually asks
    /// `AppDataSource` to look again; this button is that ask, calling
    /// `applyRemoteSettingsFromDefaults()` (`AppDataSource.swift`), which is
    /// the exact live-apply path a scanned QR pairing already used.
    private var remoteMacSection: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            Text("REMOTE MAC")
                .scaledFont(palette, size: 11, weight: .semibold)
                .kerning(0.8)
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: palette.spacingRow) {
                TextField("Address (e.g. my-mac.tailnet.ts.net)", text: $remoteHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedRemoteMacField, equals: .host)
                TextField("Port", text: $remotePort)
                    .keyboardType(.numberPad)
                    .focused($focusedRemoteMacField, equals: .port)
                TextField("Pairing code (from the Mac's Sync settings)", text: $remoteCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedRemoteMacField, equals: .code)
            }
            .textFieldStyle(.roundedBorder)

            connectButton
            remoteConnectFailureRow
            forgetRemoteMacButton

            Text("Lets this phone reach your Mac when it isn't on the same Wi-Fi. Fastest way: enable Remote Access on the Mac (Settings ▸ Sync) and scan the QR code it shows with this phone's Camera app — these fields fill themselves. Or enter the Mac's address, port, and pairing code by hand, then tap Connect. The connection is encrypted; leave the address empty to use local discovery only.")
                .scaledFont(palette, size: 11)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
    }

    /// Dismisses the keyboard, then hands the current field values to
    /// `AppDataSource` right now rather than leaving them to be picked up on
    /// some future relaunch. Disabled while a previous tap is still
    /// resolving, so a second tap can't race a second `LocalSyncClient` into
    /// existence underneath the first.
    @ViewBuilder
    private var connectButton: some View {
        Button {
            focusedRemoteMacField = nil
            Task {
                isConnectingRemote = true
                let applied = await appDataSource.applyRemoteSettingsFromDefaults()
                isConnectingRemote = false
                remoteConnectResult = applied
                    ? "Applied. Watch the Dashboard's connection line for the result."
                    : "Enter an address, port, and pairing code first."
            }
        } label: {
            HStack(spacing: palette.spacingTight) {
                if isConnectingRemote {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.background)
                }
                Text(isConnectingRemote ? "Connecting…" : "Connect")
                    .scaledFont(palette, size: 12, weight: .semibold)
                    .foregroundStyle(palette.background)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, palette.spacingTight)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: palette.cornerRadius * 0.6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isConnectingRemote)
        .accessibilityHint("Applies the address, port, and pairing code above immediately, instead of waiting for the app to relaunch.")

        if let remoteConnectResult {
            Text(remoteConnectResult)
                .scaledFont(palette, size: 10.5)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Surfaces `AppDataSource.remoteConnectFailureReason` (connection-
    /// honesty review bug #2) as a specific, actionable line instead of the
    /// generic "still trying…" the retry loop used to leave the user
    /// staring at regardless of cause. Empty when `nil` — no message shown
    /// until a direct-connect attempt has actually failed this session, and
    /// the message clears itself the moment a connection succeeds or a new
    /// endpoint is entered (see `AppDataSource.reconfigureAndResolve`).
    @ViewBuilder
    private var remoteConnectFailureRow: some View {
        if let reason = appDataSource.remoteConnectFailureReason {
            Text(remoteConnectFailureMessage(for: reason))
                .scaledFont(palette, size: 10.5, weight: .medium)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remoteConnectFailureMessage(for reason: DirectConnectFailureReason) -> String {
        switch reason {
        case .wrongPairingCode:
            return "Wrong code? The Mac rejected the pairing code above — check it against Settings ▸ Sync ▸ Remote Access on the Mac."
        case .unreachable:
            return "Mac not responding — check it's awake and on the network. The address or port above may also be wrong."
        }
    }

    /// "Forget" control for the saved remote-Mac endpoint (connection-
    /// honesty review bug #3). Hidden when there's nothing saved to forget
    /// — an always-visible button next to three empty fields would invite a
    /// confusing no-op tap. Clears the on-screen fields immediately (rather
    /// than waiting on `AppDataSource`'s async round trip) so the UI doesn't
    /// sit showing stale values while `forgetRemoteMac()` runs.
    @ViewBuilder
    private var forgetRemoteMacButton: some View {
        if !remoteHost.isEmpty || !remoteCode.isEmpty {
            Button(role: .destructive) {
                focusedRemoteMacField = nil
                remoteHost = ""
                remotePort = "8643"
                remoteCode = ""
                remoteConnectResult = nil
                Task { await appDataSource.forgetRemoteMac() }
            } label: {
                Text("Forget Remote Mac")
                    .scaledFont(palette, size: 11.5, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.danger)
            .accessibilityHint("Clears the saved address, port, and pairing code above and stops this phone from trying to reach that Mac.")
        }
    }

    // MARK: - Theme (the real, working section)

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: palette.spacing * 0.75) {
            Text("THEME")
                .scaledFont(palette, size: 10, weight: .semibold)
                .foregroundStyle(palette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: palette.spacing) {
                    ForEach(Theme.builtInPresets) { theme in
                        themeSwatch(theme)
                    }
                }
                .padding(.vertical, 2)
            }
            // Deliberately says neither "SentryKit/Settings/Theme.swift" (a
            // source path has no meaning to the person reading this) nor
            // "iCloud" (Sentry has no cloud account and no CloudKit
            // container — promising a channel that doesn't exist, in the one
            // app whose pitch is that nothing leaves your machine, is worse
            // than saying nothing). Says only what is true and useful: this
            // choice is per-device.
            Text("The same presets as the Mac app, applied to all four tabs. Your theme is stored on this device, so choosing one here doesn't change the Mac app, and vice versa.")
                .scaledFont(palette, size: 10.5)
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
    /// happened. Showing "Last synced 2m ago" one card above a row admitting
    /// this phone isn't connected to a Mac right now would be a direct,
    /// visible self-contradiction on the same screen. The meta line instead
    /// reports the one true thing this build knows about the device (its
    /// model) plus the honest state, keeping the intended two-line visual
    /// shape without inventing a sync timestamp.
    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayedDevice.deviceName)
                .scaledFont(palette, size: 12.5, weight: .medium)
                .foregroundStyle(palette.textPrimary)
            // The meta line's second half distinguishes a real local-network
            // connection from demo data — `syncStatusRow` right below is
            // scoped specifically to iCloud/CloudKit sync (still genuinely
            // unavailable, and unrelated to whether a Mac is reachable over
            // local Wi-Fi right now), not this local-network path, so this
            // is the one place on this tab that actually reflects
            // `AppDataSource.isUsingLocalSync`.
            Text("\(displayedDevice.model) · \(appDataSource.isUsingLocalSync ? "Live on your local network" : "Demo device, not synced")")
                .scaledFont(palette, size: 10.5)
                .foregroundStyle(palette.textTertiary)
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            appDataSource.isUsingLocalSync
                ? "This device is live data from a Mac reporting in over your local Wi-Fi network."
                : "This is demo data, not a real Mac — this phone isn't currently connected to a Mac over your local network, so there is nothing real on the other end reporting in."
        )
    }

    // MARK: - Multi-Mac picker (LAN/Bonjour only)

    /// Set while `AppDataSource.switchToDiscoveredMac(_:)` is in flight for
    /// a specific row — lets that one row show a spinner instead of the
    /// whole section blocking, since switching only affects the tapped Mac.
    @State private var switchingMacID: String?

    /// The real multi-Mac picker this pass adds. `LocalSyncClient`'s
    /// `preferredEndpoint(among:preferring:)` (see its doc comment) already
    /// stops a *drop* from silently reconnecting to the wrong Mac, but gave
    /// a user with two Macs on the same network no way to see the second
    /// one exists, let alone deliberately switch to it. This section is
    /// that: it lists every Mac `AppDataSource.discoveredMacs` currently
    /// reports (kept live by `LocalSyncClient.setDiscoveredMacsHandler(_:)`)
    /// and lets a tap switch to any of them via
    /// `AppDataSource.switchToDiscoveredMac(_:)`.
    ///
    /// **Gated by `hasMultipleMacs(_:)`, deliberately.** The common case is
    /// one Mac (or zero, pre-connection) — this section renders nothing at
    /// all then, matching the brief not to clutter that case with picker UI
    /// it doesn't need. It only appears once there is genuinely something
    /// to choose between.
    ///
    /// **LAN-only, on purpose.** This reads `AppDataSource.discoveredMacs`,
    /// which is populated exclusively from Bonjour browse results — the
    /// remote/TLS-PSK fallback (`remoteMacSection` below) has no discovered
    /// list at all, just one user-entered address. Supporting a picker
    /// across several *remote* Macs (multiple stored pairing codes) is a
    /// bigger, separate project, out of scope here.
    @ViewBuilder
    private var macPickerSection: some View {
        if LocalSyncClient.hasMultipleMacs(appDataSource.discoveredMacs) {
            VStack(alignment: .leading, spacing: palette.spacingRow) {
                Text("MACS ON YOUR NETWORK")
                    .scaledFont(palette, size: 11, weight: .semibold)
                    .kerning(0.8)
                    .foregroundStyle(palette.textTertiary)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: palette.spacingTight) {
                    ForEach(appDataSource.discoveredMacs) { mac in
                        macRow(mac)
                    }
                }

                Text("More than one Mac answered on your local network. Tap one to connect to it instead — your choice is remembered, so this phone reconnects to it automatically next time too.")
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(palette.spacingBlock)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(palette)
        }
    }

    /// One row per discovered Mac: name, a checkmark on whichever one
    /// `AppDataSource.connectedMacIdentity` currently matches, and a
    /// per-row spinner while a tap on a *different* row is still resolving.
    private func macRow(_ mac: DiscoveredMac) -> some View {
        let isSelected = mac.id == appDataSource.connectedMacIdentity
        return Button {
            guard LocalSyncClient.isSwitchingMac(from: appDataSource.connectedMacIdentity, to: mac) else { return }
            switchingMacID = mac.id
            Task {
                await appDataSource.switchToDiscoveredMac(mac)
                switchingMacID = nil
            }
        } label: {
            HStack(spacing: palette.spacingTight) {
                Text(mac.displayName)
                    .scaledFont(palette, size: 12.5, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                Spacer(minLength: 0)
                if switchingMacID == mac.id {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .scaledSystemFont(size: 12, weight: .semibold)
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(switchingMacID != nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "Currently connected." : "Switch to this Mac instead.")
    }

    // MARK: - Sync status (SyncPane's tone, mobile side)

    /// The iPhone-side counterpart of `Sentry/Settings/Panes/SyncPane.swift`.
    /// Deliberately mirrors that pane's wording and its list of banned
    /// phrasings ("Connected," "Syncing," "Up to date," a spinner, a
    /// fabricated record count) rather than inventing new language for the
    /// same underlying fact: this build has no iCloud container, no
    /// `CKContainer`, no push subscription, on either platform, for the same
    /// reason (`Sentry` isn't enrolled in the Apple Developer Program).
    /// Same muted "honest disclosure" row style as History's
    /// `chargeSessionGapNotice` and Alerts' `historyDisclosure` — a small
    /// outlined circle + one line of tertiary text, full explanation in the
    /// accessibility hint.
    ///
    /// **Not the reason demo data shows up (connection-honesty review, bug
    /// #6).** This row used to read "iCloud sync isn't available in this
    /// build yet," full stop — which reads, right next to `deviceCard`'s
    /// "Demo device, not synced," as though iCloud is *why* the Dashboard is
    /// showing synthetic data. It isn't: the app was never going to try
    /// iCloud for that. The actual, working transport is local-network
    /// Bonjour (`LocalSyncClient`) plus an optional remote TLS-PSK fallback
    /// (`remoteMacSection` above) — a user whose Mac is simply unreachable
    /// on Wi-Fi doesn't need a story about a cloud feature that was never
    /// involved. This row now says what's genuinely true (no iCloud channel
    /// exists in this build) without implying it's the culprit; `deviceCard`
    /// and the Dashboard's connection line are the places that actually
    /// explain *why* this phone isn't seeing a real Mac right now.
    private var syncStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .scaledSystemFont(size: 9)
                .foregroundStyle(palette.textTertiary)
            Text("This build has no iCloud sync — it reaches your Mac over your local network instead.")
                .scaledFont(palette, size: 11)
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Sentry isn't enrolled in the Apple Developer Program yet, so this phone has no iCloud container to sync through. That's unrelated to whether this phone is currently connected to a Mac — this build reaches a Mac over your local Wi-Fi network, or a remote address you configure above, never through iCloud.")
    }

    // MARK: - Notifications (informational only — no working preferences)

    /// Plan §12.1 wants "Notification preferences" here, but a preference
    /// only means something if it changes what happens later — and nothing
    /// can deliver a push notification in this build (no CloudKit
    /// subscription, no APNs registration; `AlertAction.pushToPhone`,
    /// `SentryKit/Services/AlertRule.swift`, is a documented no-op on the
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
                .scaledFont(palette, size: 10, weight: .semibold)
                .foregroundStyle(palette.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.notificationCategoryNames, id: \.self) { name in
                    Text(name)
                        .scaledFont(palette, size: 11.5)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            // Type and file names removed for the same reason as the theme
            // caption above: this is read by someone deciding whether to
            // trust the app, not by someone browsing the source.
            Text("These mirror the Mac app's alert rules — shown for reference, not as working preferences. Notifications need a live connection to your Mac, so there's nothing here to turn on or off yet.")
                .scaledFont(palette, size: 10.5)
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

    /// The widget itself is real now — `SentryWidget` renders whatever
    /// `WidgetSnapshotWriter` (`SentryMobile/Data/WidgetSnapshotWriter.swift`)
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
                .scaledSystemFont(size: 9)
                .foregroundStyle(palette.textTertiary)
            Text("Widgets show the Dashboard's latest reading — nothing to configure here yet.")
                .scaledFont(palette, size: 11)
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Add the widget from your home screen. It shows the most recent data this app cached — there are no in-app widget options to change yet.")
    }
}

// MARK: - Walkthrough row

extension SettingsTabView {
    /// Re-runs the first-run walkthrough
    /// (`SentryMobile/Onboarding/OnboardingView.swift`).
    ///
    /// **Why this writes `false` to a flag instead of presenting anything.**
    /// `SentryMobileApp` already owns the only presentation of
    /// `OnboardingView`, through a `.fullScreenCover` whose `isPresented`
    /// binding is derived from `!hasCompletedOnboarding` — deliberately, so
    /// there is exactly one source of truth for "has this run." Presenting a
    /// second copy from here (a `.sheet` on this tab, say) would create a
    /// second one, with its own dismissal path and its own opinion about the
    /// flag. Clearing the flag re-arms the *existing* mechanism, and
    /// finishing or skipping the re-run sets it again through the same
    /// `WalkthroughGate.completedFlag(after:)` call the first run uses.
    ///
    /// **Why the `@AppStorage` key is duplicated here rather than passed
    /// down.** Same tradeoff, and the same reasoning, as this file's
    /// existing `selectedThemeID`/`remoteSync.*` properties: the string key
    /// is what keeps the copies in sync, `SentryMobileApp` is a `Scene` with
    /// no view hierarchy to thread a binding through, and inventing an
    /// observable object to carry one boolean would be more machinery than
    /// this file's own precedent accepts for four other flags.
    ///
    /// **Placed above About, not below it.** About is reference material and
    /// belongs last (its own doc comment says so). The walkthrough is the
    /// thing a confused user is looking for, so it sits one row closer to
    /// where they are already scrolling.
    fileprivate var walkthroughRow: some View {
        Button {
            hasCompletedOnboarding = false
        } label: {
            HStack(spacing: palette.spacingTight) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Walkthrough")
                        .scaledFont(palette, size: 12.5)
                        .foregroundStyle(palette.textPrimary)
                    Text("The seven-step introduction, again.")
                        .scaledFont(palette, size: 11)
                        .foregroundStyle(palette.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.counterclockwise")
                    .scaledSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(palette.spacingBlock)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(palette)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show the walkthrough again")
        .accessibilityHint("Reopens the introduction that explains pairing a Mac, the four tabs, and the Watch app.")
    }
}

// MARK: - About row

extension SettingsTabView {
    /// Last row on the tab: version, credits, license acknowledgements and
    /// the privacy policy link, in `AboutView`. Bottom of the list on
    /// purpose — it is a reference surface, not something a user opens
    /// Settings to change.
    fileprivate var aboutRow: some View {
        Button {
            showsAbout = true
        } label: {
            HStack(spacing: palette.spacingTight) {
                Text("About Sentry")
                    .scaledFont(palette, size: 12.5)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                Text(AppCredits.versionSummary())
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(palette.spacingBlock)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(palette)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Version, credits, privacy policy, and third-party licenses.")
    }
}
