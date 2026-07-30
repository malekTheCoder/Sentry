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

    /// The 2-column row's approximate 1.3fr:1fr split (Nocturne mock's exact
    /// ratio), expressed as `minWidth` hints rather than a `GeometryReader`
    /// division: this row's height is driven by its tallest child (Battery
    /// Health's chart vs. Agent Activity's stat row are genuinely different
    /// heights depending on live data), and a `GeometryReader` would have to
    /// be pinned to a fixed height to compute proportional widths, fighting
    /// the natural intrinsic-height layout every other card in this scroll
    /// view already relies on. `HStack` splits any width beyond these
    /// minimums evenly, which keeps the same ~1.3:1 proportion at the
    /// window's default size and only drifts from exact ratio (never from
    /// "reads as bigger left column") as the window is resized wider.
    private static let batteryHealthMinWidth: CGFloat = 340
    private static let agentActivityMinWidth: CGFloat = 260

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                header
                HStack(alignment: .top, spacing: palette.spacing * 1.5) {
                    BatteryHeroCard(
                        battery: viewModel.snapshot?.battery,
                        powerSeries: nil
                    )
                    SleepControlCard(powerControl: powerControl)
                }
                HStack(alignment: .top, spacing: palette.spacing * 1.5) {
                    BatteryHealthTrendCard(
                        historyStore: historyStore,
                        currentCycleCount: viewModel.snapshot?.battery?.cycleCount
                    )
                    .frame(minWidth: Self.batteryHealthMinWidth, maxWidth: .infinity, alignment: .leading)
                    AgentActivityCard(summary: viewModel.agentActivity)
                        .frame(minWidth: Self.agentActivityMinWidth, maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top, spacing: palette.spacing * 1.5) {
                    AnomaliesCard(anomalies: viewModel.anomalies)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TopProcessesCard(processes: processMonitor.topProcesses)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    /// Nocturne mock: "Dashboard" (19px/600) at top-left, the time-range
    /// pill control at top-right. The machine name — genuinely useful
    /// context on a window that isn't anchored to the menu bar the way the
    /// dropdown is — moves to a small caption under the title rather than
    /// being the title itself, matching the same title+caption pattern every
    /// card on this window now uses.
    private var machineName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(palette.font(size: 19, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(machineName)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: palette.spacing)
            TimeRangePickerView(selection: $viewModel.timeRange)
        }
    }
}
