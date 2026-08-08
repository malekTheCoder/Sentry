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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacingSection) {
                header

                // Redesign spec carried over from Nocturne: an *active*
                // keep-awake countdown surfaces before anything else.
                if isSleepActive {
                    SleepStatusCard(
                        assertion: viewModel.latestSnapshot?.sleepAssertion,
                        deviceID: viewModel.selectedDevice?.deviceID ?? "unknown"
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
                        deviceID: viewModel.selectedDevice?.deviceID ?? "unknown"
                    )
                }
            }
            .padding(.horizontal, palette.spacingPage)
            .padding(.vertical, palette.spacingSection)
        }
        .themedScreenBackground(palette)
        .task { await viewModel.start() }
    }

    /// The snapshot the read-only surfaces render. `nil` while unreachable
    /// so everything degrades to "—" — the last received values are real
    /// but frozen, and frozen-presented-as-live is the lie the handoff
    /// forbids. (`SleepStatusCard` keeps the raw snapshot: an assertion
    /// countdown carries its own end time and stays meaningful.)
    private var displaySnapshot: SystemSnapshot? {
        if appDataSource.isUsingLocalSync && !appDataSource.isLocalSyncConnected {
            return nil
        }
        return viewModel.latestSnapshot
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

    private var isSleepActive: Bool {
        if case .active = viewModel.latestSnapshot?.sleepAssertion { return true }
        return false
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
