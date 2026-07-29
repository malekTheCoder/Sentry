import SwiftUI
import MacStatKit

/// Root of the settings window: one tab per pane (plan §8.2, §8.4, §9.3).
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

    init(store: SettingsStore, historyStore: HistoryStore? = nil, onShowDebugWindow: (() -> Void)? = nil) {
        self.store = store
        self.historyStore = historyStore
        self.onShowDebugWindow = onShowDebugWindow
    }

    var body: some View {
        TabView {
            GeneralPane(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }

            ModulesPane(store: store)
                .tabItem { Label("Modules", systemImage: "square.grid.2x2") }

            MenuBarPane(store: store)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            ThemePane(store: store)
                .tabItem { Label("Theme", systemImage: "paintpalette") }

            AlertsPane(store: store, historyStore: historyStore)
                .tabItem { Label("Alerts", systemImage: "bell") }

            AdvancedPane(store: store, onShowDebugWindow: onShowDebugWindow)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}
