import AppKit
import CoreLocation
import SwiftUI
import UserNotifications
import SentryKit

/// The interactive half of each Mac walkthrough step — the part that
/// actually *does* something rather than describing it.
///
/// **The rule this file was written to.** Every control below moves a real
/// dial in this build, through the same code path the corresponding
/// settings pane uses. Nothing here is a mock, a preview of a future
/// feature, or a toggle that writes a preference nothing reads — the failure
/// `SyncPane`'s doc comment names as this codebase's canonical prior bug ("a
/// settings slider that silently did nothing"). Where a real action was not
/// reachable without editing a file this branch may not touch, the step says
/// where the control lives instead of pretending to be it; there is exactly
/// one such case, the command-line bridge, and it is annotated in place.
///
/// **How each control is actually wired, since none of it is obvious:**
///
/// - **Keep Awake** writes `AppSettings.dropdownShowsKeepAwake`, which
///   `DropdownView` reads to decide whether the sleep card is in the
///   dropdown at all. This is the honest control for this step: the card
///   itself is a live `SleepControlCard` bound to `PowerControlService`, and
///   embedding a *working* sleep control inside a first-run walkthrough
///   would mean a user could take a real `IOPMAssertion` while reading an
///   introduction, with no obvious way to find it again. Making sure the
///   card is *present* is the thing this step can safely do.
///
/// - **Notifications** calls `UNUserNotificationCenter.requestAuthorization`
///   directly, with `[.alert, .sound, .badge]` — the exact option set
///   `AlertEngine.requestAuthorizationIfNeeded` uses. Deliberately not
///   routed through `AlertEngine`: that type's only public trigger is
///   `ruleWasEnabled(_:)`, it discards the grant result without publishing
///   it, and it is not reachable from here anyway (`AppDelegate`'s instance
///   is private). Asking for a *different* option set than the engine later
///   asks for would be the real bug, and this avoids it by using the same
///   one.
///
/// - **Location** writes `AppSettings.locationLogEnabled`, and that is the
///   whole mechanism: `AppDelegate.applySettings` — which is subscribed to
///   `settingsStore.$settings` — calls `LocationService.requestAuthorization()`
///   and `start()` in direct response to that flag going true. So this
///   toggle produces a genuine CoreLocation prompt through the app's own
///   opt-in path rather than a parallel one, which is exactly what
///   `AppSettings.locationLogEnabled`'s doc comment requires ("in direct
///   response to this flipping to `true` from a user tapping the toggle").
///   The status line beside it reads `CLLocationManager.authorizationStatus`
///   from a throwaway manager — a read, which prompts nothing.
///
/// - **Agent access** writes `AppSettings.mcpServerEnabled`, the master
///   switch `MCPXPCService`/`SentryMCP` gate on, and shows the live count of
///   read vs. write tools from `MCPToolID` rather than a number typed into
///   a string that can rot.
///
/// - **iPhone pairing** writes `AppSettings.remoteSyncEnabled` through the
///   same mint-a-code-first binding `SyncPane` uses (a listener with no
///   pairing code is a lock with no key), and draws the real QR with
///   `SyncPane.qrImage(host:port:code:)` against a real address from
///   `RemotePairing.hostCandidates()`. It is the same QR, of the same
///   endpoint, as the one in Settings — not a picture of one.
struct WalkthroughStepContent: View {

    let step: MacWalkthroughStep
    @ObservedObject var store: SettingsStore
    let theme: Theme
    let endpointPublisher: MCPEndpointPublisher?

    @Environment(\.themePalette) private var palette

    var body: some View {
        switch step {
        case .menuBar:
            pointerHint
        case .composeBar:
            MenuBarPreviewStrip(layout: store.settings.menuBarLayout, theme: theme)
        case .keepAwake:
            keepAwakeControl
        case .alerts:
            NotificationPermissionRow()
        case .insights:
            // Nothing. The one thing this step could show — a live
            // `ProtectionScore` — needs a `HistoryStore`, an
            // `InsightContext` and a `SecurityPosture` collection pass that
            // are not reachable from here, and a *plausible-looking* number
            // in a walkthrough is worse than no number: a first-run user has
            // no way to tell a sample from their own machine's reading. The
            // step teaches how the score is built and sends them to the real
            // one.
            EmptyView()
        case .agents:
            agentAccessControls
        case .companion:
            PairingControls(store: store)
        case .locationLog:
            LocationLogControl(store: store)
        case .done:
            doneHint
        }
    }

    // MARK: - Step 1

    /// The popover is anchored directly beneath the status item
    /// (`OnboardingCoordinator.present`), so "up" already points at the
    /// right place — this is the arrow that says so, and no custom graphic
    /// is needed to repeat what the system's own anchoring says
    /// geometrically. Carried over unchanged from `WelcomeView`.
    private var pointerHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingTight) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text("It's directly above this window, right now.")
                .font(palette.font(size: 11.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Step 3

    private var keepAwakeControl: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Toggle("Show the Keep Awake card in the dropdown", isOn: $store.settings.dropdownShowsKeepAwake)
                .accessibilityLabel("Show the Keep Awake card in the dropdown")
                .accessibilityHint("Also in Settings, Menu Bar.")
            Text("Same switch as Settings ▸ Menu Bar ▸ Dropdown shows.")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
        }
    }

    // MARK: - Step 6

    private var agentAccessControls: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Toggle("Let coding agents connect to this Mac", isOn: $store.settings.mcpServerEnabled)
                .accessibilityLabel("Let coding agents connect to this Mac")
                .accessibilityHint("Turns on Sentry's MCP server. Also in Settings, AI Access.")

            // Counted from `MCPToolID` rather than written as a literal:
            // this sentence was already stale once in this codebase (see
            // `MCPTool.swift`'s own header, which still says "14-tool
            // surface" after the surface grew), and a walkthrough is the
            // worst place for a number that drifts.
            Text("\(MCPToolID.readTools.count) read-only tools are enabled to start with; the \(MCPToolID.writeTools.count) that change something stay off until you turn each one on.")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The kill switch is *state*, and it is shown as state rather
            // than as another toggle: this walkthrough should not become a
            // second place to pause agent access, because a user who paused
            // it here would then look for the resume control in the two
            // places it actually lives (the dropdown banner, and Settings ▸
            // AI Access) and this row is where they learn those exist.
            Label {
                Text(store.settings.agentGuardrails.killSwitchEngaged
                     ? "The kill switch is on right now — every agent call is being declined. Resume it from the dropdown or Settings ▸ AI Access."
                     : "The kill switch is in the dropdown and in Settings ▸ AI Access. One toggle declines every agent call until you resume it.")
                    .font(palette.font(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                // §9.4: the icon and the sentence both carry the state, so
                // nothing depends on noticing the colour changed.
                Image(systemName: store.settings.agentGuardrails.killSwitchEngaged
                      ? "hand.raised.fill"
                      : "hand.raised")
                    .foregroundStyle(store.settings.agentGuardrails.killSwitchEngaged
                                     ? palette.warning
                                     : palette.textTertiary)
            }
            .foregroundStyle(palette.textTertiary)

            if let endpointPublisher {
                CommandLineBridgeRow(publisher: endpointPublisher)
            } else {
                // The one stated fallback in this file — see
                // `OnboardingCoordinator.showIfNeeded`'s `endpointPublisher`
                // parameter for why it can be absent and why this is a
                // sentence rather than a disabled button.
                Text("Agents that run as a command line tool need a small background helper. Settings ▸ AI Access ▸ Set Up Command-Line Access installs it.")
                    .font(palette.font(size: 10.5))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 9

    private var doneHint: some View {
        Label {
            Text("Settings ▸ General ▸ Walkthrough")
                .font(palette.font(size: 11.5, weight: .medium))
        } icon: {
            Image(systemName: "arrow.counterclockwise")
                .foregroundStyle(palette.accent)
        }
        .foregroundStyle(palette.textPrimary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Run this walkthrough again from Settings, General, Walkthrough.")
    }
}

// MARK: - Notifications

/// Asks for notification authorisation, at the moment the walkthrough is
/// explaining why Sentry would want it.
///
/// **Why the status is probed once and not observed.**
/// `UNUserNotificationCenter` publishes nothing when authorisation changes —
/// there is no KVO key and no notification to subscribe to — so a poller
/// would be the only way to stay live, and `AlertsPane` already made this
/// exact call for the same reason (its own comment: "One-time check, not a
/// poller"). The probe re-runs after a request completes, which is the only
/// transition this view can actually cause.
private struct NotificationPermissionRow: View {

    @Environment(\.themePalette) private var palette

    /// `nil` means "not checked yet", which is deliberately distinct from
    /// `.notDetermined` ("checked; macOS has never asked"). Collapsing them
    /// would make the button flicker through the wrong label on first
    /// render.
    @State private var status: UNAuthorizationStatus?

    @State private var requestFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            switch status {
            case nil:
                Text("Checking notification permission…")
                    .font(palette.font(size: 10.5))
                    .foregroundStyle(palette.textTertiary)

            case .notDetermined?:
                Button("Allow Notifications…") { request() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Asks macOS for permission to show Sentry's alerts.")

            case .denied?:
                stateRow(
                    symbol: "bell.slash",
                    tint: palette.warning,
                    text: "Notifications are turned off for Sentry. Alerts will still be recorded, but nothing will interrupt you."
                )
                Button("Open Notification Settings") { openNotificationSettings() }
                    .buttonStyle(.bordered)

            case .some(let granted):
                stateRow(
                    symbol: "bell.badge",
                    tint: palette.success,
                    text: granted == .provisional
                        ? "Sentry can deliver alerts quietly, without sound or a banner."
                        : "Sentry can deliver alerts."
                )
            }

            if let requestFailure {
                stateRow(symbol: "exclamationmark.triangle", tint: palette.warning, text: requestFailure)
            }
        }
        .task { await refresh() }
    }

    /// The icon and the sentence both carry the state — §9.4's rule, applied
    /// the same way `GeneralPane`'s battery warning and `FanControlPane`'s
    /// lock rows apply it.
    private func stateRow(symbol: String, tint: Color, text: String) -> some View {
        Label {
            Text(text)
                .font(palette.font(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .foregroundStyle(palette.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func request() {
        Task {
            do {
                // Same option set as `AlertEngine.requestAuthorizationIfNeeded`
                // — see this file's header for why matching it exactly
                // matters more than which options are in it.
                _ = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                requestFailure = nil
            } catch {
                // Surfaced, not swallowed: a request that throws (an
                // unsigned build, a managed device) otherwise looks
                // identical to a user quietly declining.
                requestFailure = error.localizedDescription
            }
            await refresh()
        }
    }

    /// Duplicated from `AlertsPane.openNotificationSettings`, which is
    /// `private`. Two identical one-line URL opens is a smaller cost than
    /// widening that pane's API for one caller; if a third appears, it
    /// belongs in a shared helper next to `SystemSettingsLink`.
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Command-line bridge

/// The same `SMAppService` registration `AIAccessPane`'s "Set Up
/// Command-Line Access…" button performs, offered at the moment the
/// walkthrough explains what it is for.
///
/// Split into its own view purely so the publisher can be a non-optional
/// `@ObservedObject` — the same shape `AIAccessPane` reaches for with its
/// `EndpointPublisherHolder`, minus the holder, because this view has
/// exactly one optional dependency and can be conditionally constructed
/// instead of conditionally populated.
private struct CommandLineBridgeRow: View {

    @ObservedObject var publisher: MCPEndpointPublisher

    @Environment(\.themePalette) private var palette

    @State private var setupFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Label {
                Text(publisher.registration.shortLabel)
                    .font(palette.font(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: publisher.registration.isUsable ? "terminal.fill" : "terminal")
                    .foregroundStyle(publisher.registration.isUsable ? palette.success : palette.textTertiary)
            }
            .foregroundStyle(palette.textSecondary)
            .accessibilityElement(children: .combine)

            if !publisher.registration.isUsable {
                Button("Set Up Command-Line Access…") { setUp() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Installs Sentry's background helper so command line agents can reach this Mac.")
            }

            if case .awaitingApproval = publisher.registration {
                Button("Open Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("macOS needs the helper approved in Login Items before it can run.")
            }

            if let setupFailure {
                Label {
                    Text(setupFailure)
                        .font(palette.font(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(palette.warning)
                }
                .foregroundStyle(palette.textSecondary)
            }
        }
        // `.awaitingApproval → .registered` happens entirely inside System
        // Settings with nothing published back, so the state is re-probed
        // whenever this row appears — same reason `AIAccessPane` refreshes
        // in `onAppear`.
        .onAppear { publisher.refresh() }
    }

    private func setUp() {
        do {
            try publisher.register()
            setupFailure = nil
        } catch {
            setupFailure = error.localizedDescription
        }
    }
}

// MARK: - iPhone pairing

/// Turns on Remote Access and draws this Mac's real pairing QR.
///
/// Everything here mirrors `SyncPane` rather than reimplementing it: the
/// enable-mints-a-code binding, `RemotePairing.hostCandidates()` for the
/// address (Tailscale ranked above LAN, so the code works off-network when
/// there is a tunnel), and `SyncPane.qrImage(host:port:code:)` for the
/// image. A user who scans this and then opens Settings ▸ Sync sees the same
/// code, because it is the same code.
private struct PairingControls: View {

    @ObservedObject var store: SettingsStore

    @Environment(\.themePalette) private var palette

    @State private var hostCandidates: [RemotePairing.HostCandidate] = []
    @State private var selectedHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Toggle("Allow connections from other networks", isOn: remoteEnabledBinding)
                .accessibilityLabel("Allow connections from other networks")
                .accessibilityHint("Turns on Remote Access and creates a pairing code. Also in Settings, Sync.")

            if store.settings.remoteSyncEnabled {
                if let qr = SyncPane.qrImage(
                    host: selectedHost,
                    port: store.settings.remoteSyncPort,
                    code: store.settings.remoteSyncPairingCode
                ) {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 116, height: 116)
                        .padding(5)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel("QR code for pairing an iPhone")
                        .accessibilityValue(qrAccessibilityValue)

                    Text(hostLabel)
                        .font(palette.font(size: 10.5))
                        .foregroundStyle(palette.textTertiary)
                } else {
                    Text("No usable address found on this Mac's interfaces — you can enter the address on the phone by hand instead.")
                        .font(palette.font(size: 10.5))
                        .foregroundStyle(palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("On the same Wi-Fi, nothing here needs turning on — the phone finds this Mac by itself.")
                    .font(palette.font(size: 10.5))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refreshHostCandidates)
    }

    /// The QR is an image of a URL, which VoiceOver cannot read and which
    /// this view must not read aloud either — the pairing code is the shared
    /// secret. The value states what the code *is for* and where the
    /// spelled-out fields live, which is what a non-sighted user actually
    /// needs to pair by hand.
    private var qrAccessibilityValue: String {
        String(localized: "Holds this Mac's address, port and pairing code. The same three values are listed in Settings, Sync.")
    }

    private var hostLabel: String {
        guard let candidate = hostCandidates.first(where: { $0.address == selectedHost }) else {
            return String(localized: "Port \(store.settings.remoteSyncPort)")
        }
        switch candidate.kind {
        case .tailscale:
            return String(localized: "\(candidate.address) — Tailscale or VPN, reachable from anywhere")
        case .lan:
            return String(localized: "\(candidate.address) — this Wi-Fi only")
        }
    }

    /// Enabling for the first time mints the pairing code — a toggle that
    /// opened a listener with no code would be a lock with no key. Lifted
    /// verbatim in intent from `SyncPane.remoteEnabledBinding`; the two must
    /// not diverge, because both write the same setting.
    private var remoteEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.remoteSyncEnabled },
            set: { enabled in
                if enabled && store.settings.remoteSyncPairingCode.isEmpty {
                    store.settings.remoteSyncPairingCode = SyncSecurity.generatePairingCode()
                }
                store.settings.remoteSyncEnabled = enabled
                if enabled { refreshHostCandidates() }
            }
        )
    }

    private func refreshHostCandidates() {
        hostCandidates = RemotePairing.hostCandidates()
        if !hostCandidates.contains(where: { $0.address == selectedHost }) {
            selectedHost = hostCandidates.first?.address ?? ""
        }
    }
}

// MARK: - Location log

/// The optional step. Writes `AppSettings.locationLogEnabled` and lets
/// `AppDelegate.applySettings` do the CoreLocation work — see this file's
/// header for why that indirection is the correct wiring and not a
/// shortcut.
private struct LocationLogControl: View {

    @ObservedObject var store: SettingsStore

    @Environment(\.themePalette) private var palette

    /// A throwaway manager, used only to *read* `authorizationStatus`.
    /// Constructing one prompts nothing (`LocationService`'s own init relies
    /// on the same fact), and this view deliberately does not construct a
    /// second `LocationService` — the app already owns one, and two
    /// instances racing to `start()` the same hardware would be a genuine
    /// bug rather than a duplicated read.
    @State private var manager = CLLocationManager()

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Toggle("Keep a location log for this Mac", isOn: $store.settings.locationLogEnabled)
                .accessibilityLabel("Keep a location log for this Mac")
                .accessibilityHint("macOS will ask for location permission. Also in Settings, Location Log.")

            Label {
                Text(statusText)
                    .font(palette.font(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: statusSymbol).foregroundStyle(statusTint)
            }
            .foregroundStyle(palette.textTertiary)
            .accessibilityElement(children: .combine)
        }
    }

    private var statusText: String {
        switch manager.authorizationStatus {
        case .notDetermined:
            return String(localized: "macOS hasn't been asked yet. Turning this on is what asks.")
        case .denied:
            return String(localized: "Location is denied for Sentry, so this will stay empty until it's allowed in System Settings ▸ Privacy & Security.")
        case .restricted:
            return String(localized: "Location is restricted on this Mac by a policy Sentry can't change.")
        case .authorized, .authorizedAlways:
            return String(localized: "Location is allowed. Sentry records a coarse position about every half hour while this is on.")
        @unknown default:
            return String(localized: "Location permission is in a state this version of Sentry doesn't recognise.")
        }
    }

    private var statusSymbol: String {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: return "location.fill"
        case .denied, .restricted: return "location.slash"
        default: return "location"
        }
    }

    private var statusTint: Color {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: return palette.success
        case .denied, .restricted: return palette.warning
        default: return palette.textTertiary
        }
    }
}
