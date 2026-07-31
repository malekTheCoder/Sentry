import SwiftUI
import MacStatKit

/// The 8 settings panes, in the Nocturne redesign's sidebar order (design
/// handoff: General, Modules, Menu Bar, Theme, Alerts, AI Access, Sync,
/// Advanced).
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, modules, menuBar, theme, alerts, aiAccess, sync, advanced

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
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

/// Root of the settings window: a native `NavigationSplitView` — system
/// sidebar material, system selection highlight, `.grouped` forms — in
/// place of the previous hand-painted sidebar and theme-tinted content.
///
/// **Deliberately not themed.** Themes style the app's own surfaces (the
/// dropdown, the Dashboard, the widgets); the settings window is where the
/// user *configures* those surfaces, and it reads as trustworthy precisely
/// by looking like every other macOS settings window. The one exception is
/// `ThemePane`'s preview cards, which render each theme with its own tokens
/// — that's the pane's whole job. `themePalette` stays in the environment
/// only for that pane.
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

    init(
        store: SettingsStore,
        historyStore: HistoryStore? = nil,
        onShowDebugWindow: (() -> Void)? = nil,
        mcpActivityLog: MCPActivityLog? = nil
    ) {
        self.store = store
        self.historyStore = historyStore
        self.onShowDebugWindow = onShowDebugWindow
        self.mcpActivityLog = mcpActivityLog
    }

    /// Optional because that's the selection type `List` binds; `detail`
    /// falls back to `.general` so the window never shows an empty pane.
    @State private var selectedPane: SettingsPane? = .general

    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            content(for: selectedPane ?? .general)
                .navigationTitle((selectedPane ?? .general).title)
        }
        .frame(minWidth: 680, minHeight: 470)
        // Only `ThemePane`'s preview cards read this — see the type doc.
        .environment(
            \.themePalette,
            ThemePalette(theme: store.resolvedTheme(), scheme: systemColorScheme)
        )
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralPane(store: store).formStyle(.grouped)
        case .modules:
            ModulesPane(store: store).formStyle(.grouped)
        case .menuBar:
            MenuBarPane(store: store).formStyle(.grouped)
        case .theme:
            ThemePane(store: store)
        case .alerts:
            AlertsPane(store: store, historyStore: historyStore).formStyle(.grouped)
        case .aiAccess:
            AIAccessPane(store: store, activityLog: mcpActivityLog).formStyle(.grouped)
        case .sync:
            SyncPane().formStyle(.grouped)
        case .advanced:
            AdvancedPane(store: store, onShowDebugWindow: onShowDebugWindow).formStyle(.grouped)
        }
    }
}
