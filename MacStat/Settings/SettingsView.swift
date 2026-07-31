import SwiftUI
import MacStatKit

/// The 8 settings panes, in the Nocturne redesign's sidebar order (design
/// handoff: General, Modules, Menu Bar, Theme, Alerts, AI Access, Sync,
/// Advanced — a different order than the tab strip this file used to have,
/// where Alerts was followed by Advanced/Sync/AIAccess).
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, modules, menuBar, theme, alerts, aiAccess, sync, location, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .modules: return "Modules"
        case .menuBar: return "Menu Bar"
        case .theme: return "Theme"
        case .alerts: return "Alerts"
        case .aiAccess: return "AI Access"
        case .sync: return "Sync"
        case .location: return "Location Log"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .modules: return "square.grid.2x2"
        case .menuBar: return "menubar.rectangle"
        case .theme: return "paintbrush"
        case .alerts: return "bell"
        case .aiAccess: return "bolt.shield"
        case .sync: return "icloud"
        case .location: return "location"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

/// Root of the settings window: a fixed-width left sidebar plus a content
/// area holding whichever pane is selected (plan §8.2, §8.4, §9.3; Nocturne
/// redesign replaces the previous native `TabView` chrome with this custom
/// sidebar, per the design handoff).
///
/// Every pane binds straight into `store.settings`, which debounces its own
/// save — there is deliberately no draft/apply copy to keep in sync.
struct SettingsView: View {

    @ObservedObject var store: SettingsStore

    /// Read-only, and only `AlertsPane`'s history mode uses it. `nil` is a
    /// legitimate configuration — the settings window is constructible before
    /// history is wired, and that pane says so on screen rather than showing
    /// an empty list that would read as "nothing has ever fired."
    let historyStore: HistoryStore?

    /// Passed straight through to `AdvancedPane`'s "Show Debug Window"
    /// button. `nil` is a legitimate configuration (e.g. a settings window
    /// built without the app delegate's debug window controller wired up),
    /// same as `historyStore` above.
    let onShowDebugWindow: (() -> Void)?

    /// Passed straight through to `AIAccessPane`. `nil` is a legitimate
    /// configuration, same as `historyStore`/`onShowDebugWindow` above.
    let mcpActivityLog: MCPActivityLog?

    /// Backs `LocationPane`. Unlike `historyStore`/`mcpActivityLog`, this
    /// isn't optional — `LocationService` has no meaningful "unavailable"
    /// state of its own (unlike a database that can fail to open), so
    /// `AppDelegate` always constructs a real instance and this view always
    /// has one to observe.
    @ObservedObject var locationService: LocationService

    init(
        store: SettingsStore,
        historyStore: HistoryStore? = nil,
        onShowDebugWindow: (() -> Void)? = nil,
        mcpActivityLog: MCPActivityLog? = nil,
        locationService: LocationService
    ) {
        self.store = store
        self.historyStore = historyStore
        self.onShowDebugWindow = onShowDebugWindow
        self.mcpActivityLog = mcpActivityLog
        self.locationService = locationService
    }

    @State private var selectedPane: SettingsPane = .general

    @Environment(\.colorScheme) private var systemColorScheme

    private var palette: ThemePalette {
        ThemePalette(theme: store.resolvedTheme(), scheme: systemColorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
        }
        .frame(minWidth: 640, minHeight: 440)
        .environment(\.themePalette, palette)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                sidebarRow(for: pane)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 180, alignment: .top)
        .frame(maxHeight: .infinity)
        .background(palette.surface)
    }

    private func sidebarRow(for pane: SettingsPane) -> some View {
        let isSelected = pane == selectedPane
        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .frame(width: 16)
                Text(pane.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? palette.accent.opacity(0.13) : Color.clear)
            )
            .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedPane {
        case .general:
            GeneralPane(store: store)
        case .modules:
            ModulesPane(store: store)
        case .menuBar:
            MenuBarPane(store: store)
        case .theme:
            ThemePane(store: store)
        case .alerts:
            AlertsPane(store: store, historyStore: historyStore)
        case .aiAccess:
            AIAccessPane(store: store, activityLog: mcpActivityLog)
        case .sync:
            SyncPane()
        case .location:
            LocationPane(store: store, locationService: locationService)
        case .advanced:
            AdvancedPane(store: store, onShowDebugWindow: onShowDebugWindow)
        }
    }
}
