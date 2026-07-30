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

    /// Owned by `AppDelegate`, not this view: the Dashboard window is a
    /// reused singleton whose content view never truly disappears (see
    /// `HistoryWindowController`'s doc comment), so SwiftUI's own
    /// `.onDisappear` never fires here and a `@StateObject` tied to this
    /// view's lifetime couldn't stop the monitor when the window closes.
    /// `AppDelegate` starts/stops it via `HistoryWindowController`'s
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
    // app run (`HistoryWindowController` reuses the window forever), so a
    // captured theme would freeze at whatever was active the first time the
    // Dashboard was opened. See `DashboardViewModel.theme`'s doc comment.
    private var palette: ThemePalette {
        ThemePalette(theme: viewModel.theme, scheme: systemColorScheme)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                header
                BatteryHeroCard(
                    battery: viewModel.snapshot?.battery,
                    powerSeries: nil
                )
                SleepControlCard(powerControl: powerControl)
                TimeRangePickerView(selection: $viewModel.timeRange)
                BatteryHealthTrendCard(
                    historyStore: historyStore,
                    currentCycleCount: viewModel.snapshot?.battery?.cycleCount
                )
                AnomaliesCard(anomalies: viewModel.anomalies)
                AgentActivityCard(summary: viewModel.agentActivity)
                TopProcessesCard(processes: processMonitor.topProcesses)
                DashboardGrid(
                    snapshot: viewModel.snapshot,
                    series: viewModel.series,
                    enabledModules: viewModel.enabledModules
                )
            }
            .padding(palette.spacing * 2)
        }
        .background(palette.background)
        .environment(\.themePalette, palette)
        // `DashboardViewModel.refresh()` is explicitly not automatic on
        // init (see its doc comment — constructing the view model at
        // `AppDelegate` launch time must stay cheap) — this is the one call
        // site responsible for the first history query, matching the
        // window's actual first appearance rather than app launch.
        .task {
            viewModel.refresh()
        }
    }

    // MARK: - Header

    private var machineName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private var header: some View {
        Text(machineName)
            .font(palette.font(size: 18, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
    }
}
