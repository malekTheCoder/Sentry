import SwiftUI
import SentryKit

/// Tab 1 — Dashboard, on the redesign handoff's iOS structure (2b): the
/// Mac's name as a 28pt large title, a connection sentence with a status
/// dot under it, the battery hero, the full-width Activity chart, then the
/// borderless vitals ledger. See `VitalsLedger.swift` for the ledger and
/// chart, `BatteryHeroCard.swift` for the hero.
///
/// **Connection honesty is structural here.** The handoff's rule: when the
/// Mac is unreachable, EVERY value degrades to "—" — never stale numbers
/// presented as live. That's implemented by handing the ledger and hero a
/// `nil` snapshot when the connection is lost (their existing nil-handling
/// renders em dashes), not by overlaying a banner on stale data.
///
/// **Demo data is no longer this tab's job to disclose.** The connection
/// sentence used to carry an amber "Demo data — not from a real Mac" state,
/// which was the app's most prominent disclosure and still scrolled out of
/// sight after two flicks — and only ever existed on this one tab.
/// `RootTabView` now pins `DemoDataBanner` above all four tabs
/// (`SentryMobile/Disclosure/DemoDataBanner.swift`), so `connectionLine`
/// below is scoped back to what it is actually good at: how *live* a real
/// connection is. Its demo case is gone rather than kept-and-reworded,
/// because two wordings of one fact is how the app got here.
///
/// What this tab does keep is the inline `SAMPLE` tag on the surfaces that
/// render fabricated numbers as if they were telemetry — the activity chart
/// and the vitals ledger. See `View.demoDataTagged(_:alignment:)` for how far
/// that was taken and what was rejected.
struct DashboardTabView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var appDataSource: AppDataSource
    @Environment(\.themePalette) private var palette

    /// Bumped by the connection line's Retry button, purely as a haptic
    /// trigger.
    ///
    /// **Why this is the one place on this tab that reaches for
    /// `haptic(_:onTapOf:)`,** which that modifier's own doc comment asks
    /// for a second's thought about. The thought: `retryConnection()`'s
    /// effect is not observable as a state change that coincides with the
    /// tap. It tears the transport down and re-runs discovery, which takes
    /// up to `AppDataSource.discoveryTimeout` seconds and may end exactly
    /// where it started. Keying the feedback off `isLocalSyncConnected`
    /// instead would fire whenever a Mac came back on its own — a value
    /// updating by itself, which this app's haptic header rules out — and
    /// would fire nothing at all for the retry that failed, which is the
    /// case a user is most likely to be poking at repeatedly.
    @State private var retryTaps = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacingSection) {
                header

                // Redesign spec carried over from Nocturne: an *active*
                // keep-awake countdown surfaces before anything else.
                if isSleepActive {
                    SleepStatusCard(
                        assertion: viewModel.latestSnapshot?.sleepAssertion,
                        deviceID: viewModel.selectedDevice?.deviceID ?? "unknown",
                        isMacUnreachable: isMacUnreachable
                    )
                }

                BatteryHeroCard(battery: displaySnapshot?.battery)

                // Bottom-trailing, not the default top-trailing: the chart's
                // top row is its own legend and a right-aligned "last 60 s"
                // caption, and the tag landed on top of that caption. The
                // bottom-right of the plot is empty (the avg/peak sentence is
                // leading-aligned), so the tag sits in free space against the
                // chart itself rather than over a label.
                MobileActivityChart(series: viewModel.recentSeries)
                    .demoDataTagged(marksDemoValues, alignment: .bottomTrailing)

                VStack(alignment: .leading, spacing: palette.spacingRow) {
                    HStack(spacing: palette.spacingTight) {
                        Text("VITALS")
                            .scaledFont(palette, size: 11, weight: .semibold)
                            .kerning(0.8)
                            .foregroundStyle(palette.textTertiary)
                            .accessibilityAddTraits(.isHeader)
                        if marksDemoValues {
                            DemoDataTag()
                        }
                    }
                    VitalsLedger(snapshot: displaySnapshot, series: viewModel.recentSeries)
                }

                if !isSleepActive {
                    SleepStatusCard(
                        assertion: viewModel.latestSnapshot?.sleepAssertion,
                        deviceID: viewModel.selectedDevice?.deviceID ?? "unknown",
                        isMacUnreachable: isMacUnreachable
                    )
                }
            }
            .padding(.horizontal, palette.spacingPage)
            .padding(.vertical, palette.spacingSection)
        }
        .themedScreenBackground(palette)
        .task { await viewModel.start() }
        // Attached out here rather than inside `connectionLine`: that view
        // lives in a `TimelineView(.periodic(...))` which rebuilds every five
        // seconds, and a trigger modifier rebuilt out from under itself is a
        // trigger that may or may not still be watching the value it was
        // given. Retry is `.tap` — `SentryHaptic.tap` names it outright.
        .haptic(.tap, onTapOf: retryTaps)
    }

    /// The snapshot the read-only surfaces render. `nil` while unreachable
    /// so everything degrades to "—" — the last received values are real
    /// but frozen, and frozen-presented-as-live is the lie the handoff
    /// forbids. (`SleepStatusCard` keeps the raw snapshot: an assertion
    /// countdown carries its own end time and stays meaningful — but it
    /// takes `isMacUnreachable` alongside it, because an *indefinite* hold
    /// carries no such self-correcting end time and its "● Active" pill
    /// was this rule's one leak: frozen-presented-as-live, on the exact
    /// card that reports whether the Mac is being held awake.)
    private var displaySnapshot: SystemSnapshot? {
        if isMacUnreachable {
            return nil
        }
        return viewModel.latestSnapshot
    }

    /// The tab's one unreachable predicate — the same expression
    /// `displaySnapshot` has always keyed off, named so the sleep card and
    /// the blanking rule provably share it rather than each spelling their
    /// own transport check that could drift.
    private var isMacUnreachable: Bool {
        appDataSource.isUsingLocalSync && !appDataSource.isLocalSyncConnected
    }

    /// Whether the chart and ledger should wear their own `SAMPLE` tags.
    /// Derived from the same `DemoDataDisclosure` decision the app-level
    /// banner uses — not from a second predicate — so a tagged chart and an
    /// untagged banner (or the reverse) is not a state this tab can produce.
    /// The `isQuieted:` argument is deliberately `false` here: quieting is a
    /// statement about the banner, and `Prominence.marksIndividualValues` is
    /// true for the quieted form too.
    private var marksDemoValues: Bool {
        DemoDataDisclosure
            .prominence(isShowingDemoData: appDataSource.isShowingDemoData, isQuieted: false)
            .marksIndividualValues
    }

    /// Whether the sleep card earns top billing. `isCrediblyActive`, not a
    /// bare `.active` match: a cached timed hold whose own `expiresAt` has
    /// passed certainly released (see `SleepAssertionState.isCrediblyActive
    /// (asOf:)`), and promoting it above the battery hero would headline
    /// the tab with a hold that no longer exists. The card itself still
    /// renders the ended state — down in its usual slot, with its
    /// `expiredNotice` explaining — so the fact isn't hidden, just no
    /// longer the lead story.
    private var isSleepActive: Bool {
        viewModel.latestSnapshot?.sleepAssertion?.isCrediblyActive(asOf: Date()) ?? false
    }

    // MARK: - Header

    /// Large title = the Mac's name (the phone shows one Mac's stats; that
    /// Mac is the subject of the whole screen), connection sentence under
    /// it. If more than one Mac ever reports, the picker replaces the
    /// static title.
    private var header: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            if viewModel.devices.count > 1 {
                Picker("Device", selection: $viewModel.selectedDeviceID) {
                    ForEach(viewModel.devices, id: \.deviceID) { device in
                        Text(device.deviceName).tag(Optional(device.deviceID))
                    }
                }
                .pickerStyle(.menu)
                .tint(palette.textPrimary)
                // Choosing which Mac to look at is moving between options in
                // a set, same as the range selector and the module chips.
                //
                // Attached inside this branch, not to the header, so the
                // trigger only exists once there is a picker: `selectedDeviceID`
                // is also written once programmatically, by
                // `DashboardViewModel.start()`, and a modifier installed
                // before that write could read it as a selection the user
                // made. The `when:` guard covers the same hazard from the
                // other side — nothing that lands *on* `nil` is a choice
                // anybody made.
                .haptic(.selection, on: viewModel.selectedDeviceID) { $0 != nil }
            } else {
                Text(viewModel.selectedDevice?.deviceName ?? "Mac")
                    .scaledFont(palette, size: 28, weight: .bold)
                    .foregroundStyle(palette.textPrimary)
            }
            // Hidden entirely in demo mode: the app-level banner directly
            // above this header already says the numbers are a sample and
            // already carries the retry, and a second amber line four points
            // below it saying a near-identical thing is how a reader learns
            // to skim past both.
            if !appDataSource.isShowingDemoData {
                connectionLine
            }
        }
    }

    /// 6pt dot + one sentence, per the handoff: green "Live · updated 2 s
    /// ago", gray "unreachable · last seen …". A slow clock ages the caption
    /// without re-rendering the whole screen.
    ///
    /// **The amber demo-data state this used to have is gone**, and the
    /// header above does not render this line at all in demo mode — see this
    /// type's doc comment. What remains is only ever about a *real*
    /// transport: live, connecting, or unreachable.
    ///
    /// **Retry (connection-honesty review, bug #1).** Before this existed,
    /// demo data was a dead end: `AppDataSource.resolveIfNeeded()` runs once
    /// per launch, so a Mac that was merely asleep or briefly slow meant the
    /// only way back to a real connection was force-quitting the app. The
    /// non-live states (demo and unreachable) are now a `Button` that calls
    /// `AppDataSource.retryConnection()` — the same reconnect path
    /// `SentryMobileApp`'s `scenePhase` observer uses on foreground — with a
    /// small trailing "Retry" affordance so the tap target doesn't have to
    /// be inferred from the sentence alone. Disabled and hidden while
    /// already live: retrying a working connection has nothing useful to do.
    private var connectionLine: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let state = connectionState(now: context.date)
            Button {
                retryTaps += 1
                Task { await appDataSource.retryConnection() }
            } label: {
                HStack(spacing: palette.spacingTight) {
                    Circle()
                        .fill(state.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(state.sentence)
                        .scaledFont(palette, size: 12)
                        .foregroundStyle(palette.textSecondary)
                    if !appDataSource.isLocalSyncConnected {
                        Text("Retry")
                            .scaledFont(palette, size: 12, weight: .semibold)
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(appDataSource.isLocalSyncConnected)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(appDataSource.isLocalSyncConnected ? [] : [.isButton])
            .accessibilityHint(
                appDataSource.isLocalSyncConnected
                    ? ""
                    : "Double-tap to try reconnecting to a Mac on your local network."
            )
        }
    }

    private func connectionState(now: Date) -> (color: Color, sentence: String) {
        if !appDataSource.isLocalSyncConnected {
            let suffix = viewModel.selectedDevice.map {
                " · last seen \($0.lastSeen.formatted(date: .omitted, time: .shortened))"
            } ?? ""
            return (palette.textTertiary, "Unreachable\(suffix)")
        }
        guard let timestamp = viewModel.latestSnapshot?.timestamp else {
            return (palette.textTertiary, "Connecting…")
        }
        let age = max(0, now.timeIntervalSince(timestamp))
        let ageText = age < 60 ? "\(Int(age)) s" : "\(Int(age / 60)) m"
        return (palette.success, "Live · updated \(ageText) ago")
    }
}
