import SwiftUI
import MacStatKit

/// The 8 settings panes, in the Nocturne redesign's sidebar order.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, modules, menuBar, theme, alerts, aiAccess, sync, location, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .modules: return String(localized: "Modules")
        case .menuBar: return String(localized: "Menu Bar")
        case .theme: return String(localized: "Theme")
        case .alerts: return String(localized: "Alerts")
        case .aiAccess: return String(localized: "AI Access")
        case .sync: return String(localized: "Sync")
        case .location: return String(localized: "Location Log")
        case .advanced: return String(localized: "Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .modules: return "square.grid.2x2.fill"
        case .menuBar: return "menubar.rectangle"
        case .theme: return "paintbrush.fill"
        case .alerts: return "bell.badge.fill"
        case .aiAccess: return "bolt.shield.fill"
        case .sync: return "arrow.triangle.2.circlepath.icloud.fill"
        case .location: return "location.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }

    /// System Settings-style icon chip tint. Chosen from the system palette
    /// so the sidebar reads native at a glance.
    var chipColor: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .modules: return .blue
        case .menuBar: return .indigo
        case .theme: return .purple
        case .alerts: return .red
        case .aiAccess: return .orange
        case .sync: return .cyan
        case .location: return .green
        case .advanced: return Color(nsColor: .darkGray)
        }
    }

    /// One quiet sentence under the pane title, so every pane opens with
    /// context instead of controls floating in space.
    var subtitle: String {
        switch self {
        case .general: return String(localized: "Startup, sampling cadence, and data retention.")
        case .modules: return String(localized: "Which metric modules Sentry samples and shows.")
        case .menuBar: return String(localized: "Compose the bar item and choose what the dropdown shows.")
        case .theme: return String(localized: "How Sentry's own surfaces look — dropdown, dashboard, widgets.")
        case .alerts: return String(localized: "Rules, notifications, and alert history.")
        case .aiAccess: return String(localized: "MCP tools for AI agents, local and remote.")
        case .sync: return String(localized: "iPhone companion and device sync.")
        case .location: return String(localized: "Opt-in last-known-location log for this Mac — not Find My.")
        case .advanced: return String(localized: "Diagnostics and debugging.")
        }
    }
}

/// Root of the settings window: a hand-built two-pane shell in the System
/// Settings idiom — sidebar over real behind-window material with colored
/// icon chips, an inline pane title in the content column, and **no
/// toolbar**. `NavigationSplitView` was tried and rejected: its unified
/// toolbar adds a second bar above the content that reads as chrome for
/// chrome's sake in a window this small. This view now lives as the
/// Settings tab of Sentry's one window (`MainWindowView`), under the
/// floating glass switcher — so the whole surface is these two columns.
///
/// **Deliberately not themed.** Themes style the app's own surfaces (the
/// dropdown, the Dashboard, the widgets); the settings window earns trust
/// by looking like macOS. `themePalette` stays in the environment only for
/// `ThemePane`'s live preview cards.
struct SettingsView: View {

    @ObservedObject var store: SettingsStore

    /// Read-only, and only `AlertsPane`'s history mode uses it. `nil` is a
    /// legitimate configuration — the settings window is constructible before
    /// history is wired, and that pane says so on screen rather than showing
    /// an empty list that would read as "nothing has ever fired."
    let historyStore: HistoryStore?

    /// Passed straight through to `AdvancedPane`'s "Show Debug Window"
    /// button. `nil` is a legitimate configuration, same as `historyStore`.
    let onShowDebugWindow: (() -> Void)?

    /// Passed straight through to `AIAccessPane`. `nil` is a legitimate
    /// configuration, same as the two above.
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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 720, minHeight: 500)
        // Only `ThemePane`'s preview cards read this — see the type doc.
        .environment(
            \.themePalette,
            ThemePalette(theme: store.resolvedTheme(), scheme: systemColorScheme)
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Clears the floating glass switcher; the switcher names the
            // window, so the sidebar goes straight to its rows.
            Color.clear
                .frame(height: MainWindowView.navHeight)

            ForEach(SettingsPane.allCases) { pane in
                sidebarRow(for: pane)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 200, alignment: .top)
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }

    private func sidebarRow(for pane: SettingsPane) -> some View {
        let isSelected = pane == selectedPane
        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 8) {
                chip(for: pane)
                Text(pane.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The System Settings icon treatment: white glyph on a small colored
    /// rounded square. This is most of what makes a sidebar read "native
    /// settings" rather than "list of links."
    private func chip(for pane: SettingsPane) -> some View {
        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            .fill(pane.chipColor.gradient)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: pane.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedPane.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(selectedPane.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, MainWindowView.navHeight + 4)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            content(for: selectedPane)
                // System Settings caps its form column; unbounded grouped
                // forms stretch sliders to absurd widths on a big window.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.62))
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
        case .location:
            LocationPane(store: store, locationService: locationService).formStyle(.grouped)
        case .advanced:
            AdvancedPane(store: store, onShowDebugWindow: onShowDebugWindow).formStyle(.grouped)
        }
    }
}
