import SwiftUI
import MacStatKit

/// Root of the full-window Dashboard (plan §12.1) — the deep-dive
/// counterpart to `DropdownView`'s compact 320pt popover. Same theming
/// pattern as `DropdownView` (compute `ThemePalette` from the injected
/// `Theme` plus the live `colorScheme`, inject it into the environment so
/// every subview reads `@Environment(\.themePalette)` instead of each one
/// re-deriving it), same "one view model, live headlines plus on-demand
/// history" shape as `DashboardViewModel` describes — this view just lays
/// those pieces out.
///
/// **Layout, top to bottom:** header (device name, mirroring
/// `DropdownHeader`'s `Host.current().localizedName` source) → the existing
/// `BatteryHeroCard`, reused as-is since it's a plain parameterized view
/// with no dropdown-specific assumptions baked in → `TimeRangePickerView`,
/// bound to the view model so every chart below it reacts to the same
/// selection → `BatteryHealthTrendCard`, which deliberately ignores that
/// picker (see its own doc comment) → `DashboardGrid` for the rest of the
/// enabled modules, the whole lower section wrapped in one `ScrollView`
/// since the grid has no height cap of its own.
struct DashboardView: View {
    @ObservedObject private var viewModel: DashboardViewModel
    @Environment(\.colorScheme) private var systemColorScheme

    /// `BatteryHealthTrendCard` manages its own all-time query rather than
    /// going through `DashboardViewModel.series` (see that card's doc
    /// comment), so it needs the same `HistoryStore` instance directly —
    /// the same one `AppDelegate` already handed to `viewModel`, passed
    /// alongside it rather than exposing a redundant accessor on the view
    /// model just to unwrap it back out here.
    private let historyStore: HistoryStore

    /// Owned by `AppDelegate`, not this view: Sentry's one window is a
    /// reused singleton whose content view never truly disappears (see
    /// `MainWindowController`'s doc comment), so SwiftUI's own
    /// `.onDisappear` never fires here and a `@StateObject` tied to this
    /// view's lifetime couldn't stop the monitor when the window closes.
    /// `AppDelegate` starts/stops it via `MainWindowController`'s
    /// `onShow`/`onHide` hooks instead — this view just renders whatever
    /// it's currently publishing.
    @ObservedObject private var processMonitor: ProcessMonitor

    /// Same singleton `AppDelegate` hands `DropdownView` — one live service,
    /// not a Dashboard-local copy, so extending/truncating/ending a session
    /// from this window and from the menu bar dropdown always agree (there's
    /// exactly one `IOPMAssertionID` to describe either way).
    @ObservedObject private var powerControl: PowerControlService

    /// `@MainActor` for the same reason `DropdownView.init` is — `viewModel`
    /// is main-actor isolated, and every real caller (AppDelegate, a
    /// `#Preview`) already is too.
    @MainActor
    init(
        viewModel: DashboardViewModel,
        historyStore: HistoryStore,
        processMonitor: ProcessMonitor,
        powerControl: PowerControlService
    ) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._processMonitor = ObservedObject(wrappedValue: processMonitor)
        self._powerControl = ObservedObject(wrappedValue: powerControl)
        self.historyStore = historyStore
    }

    // Reads `viewModel.theme` live rather than a `let` captured once at
    // init — this view's `NSHostingController` is built exactly once per
    // app run (`MainWindowController` reuses the window forever), so a
    // captured theme would freeze at whatever was active the first time the
    // Dashboard was opened. See `DashboardViewModel.theme`'s doc comment.
    private var palette: ThemePalette {
        ThemePalette(theme: viewModel.theme, scheme: systemColorScheme)
    }

    /// The 2-column row's approximate 1.3fr:1fr split (Nocturne mock's exact
    /// ratio), expressed as `minWidth` hints rather than a `GeometryReader`
    /// division: this row's height is driven by its tallest child (Battery
    /// Health's chart vs. the Energy card's rows are genuinely different
    /// heights depending on live data), and a `GeometryReader` would have to
    /// be pinned to a fixed height to compute proportional widths, fighting
    /// the natural intrinsic-height layout every other card in this scroll
    /// view already relies on. `HStack` splits any width beyond these
    /// minimums evenly, which keeps the same ~1.3:1 proportion at the
    /// window's default size and only drifts from exact ratio (never from
    /// "reads as bigger left column") as the window is resized wider.
    private static let batteryHealthMinWidth: CGFloat = 340
    private static let energyMinWidth: CGFloat = 260

    /// Row gap inside a section; sections themselves are separated by their
    /// headers. One constant so nothing is "randomly placed" — every gap on
    /// this window is this, or the header's own spacing.
    private var rowGap: CGFloat { palette.spacing * 1.5 }

    /// Battery rides the 30s slow tier — give it 45s of session age before
    /// letting the hero claim the Mac has no battery at all.
    private var isBatteryWarmingUp: Bool {
        guard viewModel.latestBattery == nil else { return false }
        guard let first = viewModel.firstSnapshotAt else { return true }
        return Date().timeIntervalSince(first) < 45
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                header

                GlanceStrip(
                    snapshot: viewModel.snapshot,
                    series: viewModel.series,
                    enabledModules: viewModel.enabledModules
                )

                sectionHeader("Power")
                HStack(alignment: .top, spacing: rowGap) {
                    BatteryOverviewCard(
                        historyStore: historyStore,
                        battery: viewModel.latestBattery,
                        isWarmingUp: isBatteryWarmingUp
                    )
                    .frame(minWidth: Self.batteryHealthMinWidth, maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: rowGap) {
                        // The dropdown's box-free card, given this window's
                        // standard card chrome so the column reads as
                        // siblings rather than a card and a floating group.
                        SleepControlCard(powerControl: powerControl)
                            .dashboardCard(palette)
                        EnergyReportCard(historyStore: historyStore)
                    }
                    .frame(minWidth: Self.energyMinWidth, maxWidth: .infinity, alignment: .leading)
                }

                sectionHeader("Activity")
                HStack(alignment: .top, spacing: rowGap) {
                    AgentActivityCard(
                        summary: viewModel.agentActivity,
                        agentProcesses: Array(processMonitor.agentProcesses.prefix(4))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    AnomaliesCard(anomalies: viewModel.anomalies)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TopProcessesCard(processes: Array(processMonitor.topProcesses.prefix(5)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                sectionHeader("History")
                DashboardGrid(
                    snapshot: viewModel.snapshot,
                    series: viewModel.series,
                    enabledModules: viewModel.enabledModules
                )
            }
            .padding(.horizontal, palette.spacing * 2)
            .padding(.bottom, palette.spacing * 2)
            .padding(.top, palette.spacing * 1.5)
        }
        .themedBackdrop(palette)
        .environment(\.themePalette, palette)
        // `DashboardViewModel.refresh()` is explicitly not automatic on
        // init (see its doc comment) — this is the one call site
        // responsible for the first history query, matching the window's
        // actual first appearance rather than app launch.
        .task {
            viewModel.refresh()
        }
    }

    // MARK: - Header

    /// Nocturne mock: "Dashboard" (19px/600) at top-left, the time-range
    /// pill control at top-right. The machine name — genuinely useful
    /// context on a window that isn't anchored to the menu bar the way the
    /// dropdown is — moves to a small caption under the title rather than
    /// being the title itself, matching the same title+caption pattern every
    /// card on this window now uses.
    private var machineName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// No "Dashboard" h1 — the nav bar's switcher already names the view,
    /// and saying it twice within 60pt was pure noise. The header's job is
    /// the two things the switcher can't say: whose Mac, and how fresh.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(machineName)
                    .font(palette.font(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                // Slow clock (10s) purely to age the caption — same
                // pattern and reasoning as the dropdown's status block.
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    Text(headerCaption(now: context.date))
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            Spacer(minLength: palette.spacing)
            TimeRangePickerView(selection: $viewModel.timeRange)
        }
        .padding(.bottom, palette.spacing * 0.5)
    }

    /// "updated 4s ago" — proof the numbers are alive. Quiet until the
    /// first snapshot lands.
    private func headerCaption(now: Date) -> String {
        guard let timestamp = viewModel.snapshot?.timestamp else { return "starting up…" }
        let age = max(0, now.timeIntervalSince(timestamp))
        if age < 60 { return "updated \(Int(age))s ago" }
        return "updated \(Int(age / 60))m ago"
    }

    /// The organizing device this window was missing: a small uppercase
    /// label above each band of cards, so the page reads as Power →
    /// Activity → History instead of a pile of boxes. Tertiary and tracked
    /// out — a wayfinding whisper, never competing with card titles.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(palette.font(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(palette.textTertiary)
            .padding(.top, palette.spacing)
            .accessibilityAddTraits(.isHeader)
    }
}
