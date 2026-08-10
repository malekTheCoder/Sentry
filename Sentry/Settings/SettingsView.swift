import SwiftUI
import SentryKit

/// The settings panes, in the Nocturne redesign's sidebar order.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, modules, menuBar, theme, alerts, fans, aiAccess, sync, location, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .modules: return String(localized: "Modules")
        case .menuBar: return String(localized: "Menu Bar")
        case .theme: return String(localized: "Theme")
        case .alerts: return String(localized: "Alerts")
        case .fans: return String(localized: "Fans")
        case .aiAccess: return String(localized: "AI Access")
        case .sync: return String(localized: "Sync")
        case .location: return String(localized: "Location Log")
        case .advanced: return String(localized: "Advanced")
        case .about: return String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .modules: return "square.grid.2x2"
        case .menuBar: return "menubar.rectangle"
        case .theme: return "paintbrush"
        case .alerts: return "bell.badge"
        case .fans: return "fan"
        case .aiAccess: return "bolt.shield"
        case .sync: return "arrow.triangle.2.circlepath.icloud"
        case .location: return "location"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }

    /// One quiet sentence under the pane title, so every pane opens with
    /// context instead of controls floating in space.
    var subtitle: String {
        switch self {
        case .general: return String(localized: "Startup, sampling cadence, and software updates.")
        case .modules: return String(localized: "Which metric modules Sentry samples and shows.")
        case .menuBar: return String(localized: "Compose the bar item and choose what the dropdown shows.")
        case .theme: return String(localized: "How Sentry's own surfaces look — dropdown, dashboard, widgets.")
        case .alerts: return String(localized: "Rules, notifications, and alert history.")
        case .fans: return String(localized: "Live fan speeds, and what fan control would need to work.")
        case .aiAccess: return String(localized: "MCP tools for AI agents, local and remote.")
        case .sync: return String(localized: "iPhone companion and device sync.")
        case .location: return String(localized: "An opt-in log of where this Mac last was, sent to your iPhone over local Wi-Fi.")
        case .advanced: return String(localized: "Diagnostics and debugging.")
        case .about: return String(localized: "Version, credits, and licenses.")
        }
    }
}

/// Root of the settings tab: a hand-built two-pane shell — themed sidebar,
/// an inline pane title in the content column, and **no toolbar**.
/// `NavigationSplitView` was tried and rejected: its unified toolbar adds
/// a second bar above the content that reads as chrome for chrome's sake
/// in a window this small. This view lives as the Settings tab of Sentry's
/// one window (`MainWindowView`), under the themed switcher.
///
/// **Themed like the rest of the app.** This shell used to imitate System
/// Settings (material sidebar, colored icon chips) on the theory that
/// settings earn trust by looking native — in practice it read as a
/// different app bolted onto a themed window. The sidebar and detail
/// column now draw from the same `ThemePalette` as Dashboard and Insights:
/// monochrome icons, quiet surface fills for selection (never accent), the
/// theme's own background behind the grouped forms. The forms themselves
/// stay native controls — the *chrome* is what themes.
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

    /// Backs `AIAccessPane`'s Command-Line Access section. Optional for the
    /// same reason `mcpActivityLog` is — this view is constructible in a
    /// preview or a future settings surface hosted outside `AppDelegate` —
    /// and, like that one, `nil` is rendered as an explicit "unavailable"
    /// state rather than as a section that quietly isn't there. A user who
    /// went looking for the setup button and found no section at all would
    /// reasonably conclude the feature had been removed.
    let endpointPublisher: MCPEndpointPublisher?

    /// Backs `FanControlPane`. Not optional, for the same reason
    /// `locationService` isn't: `FanControlService` has a real, meaningful
    /// answer for every hardware situation it can encounter (including "no
    /// fans" and "couldn't read"), so there is no genuine "unavailable"
    /// state that a `nil` would represent — and inventing one would give
    /// that pane a fourth empty state that can never actually occur.
    @ObservedObject var fanControlService: FanControlService

    /// Backs `LocationPane`. Unlike `historyStore`/`mcpActivityLog`, this
    /// isn't optional — `LocationService` has no meaningful "unavailable"
    /// state of its own (unlike a database that can fail to open), so
    /// `AppDelegate` always constructs a real instance and this view always
    /// has one to observe.
    @ObservedObject var locationService: LocationService

    /// Backs `GeneralPane`'s Updates section. Optional, like `historyStore`
    /// and `mcpActivityLog` and unlike the two services above: this view is
    /// constructible in contexts with no app-lifetime updater (a preview, a
    /// future settings surface hosted outside `AppDelegate`), and the pane
    /// has a truthful thing to say for `nil` — it prints that this copy has
    /// no update channel wired rather than showing a dead button. Passing
    /// `nil` is therefore a real configuration, not a placeholder.
    let updateController: UpdateController?

    init(
        store: SettingsStore,
        historyStore: HistoryStore? = nil,
        onShowDebugWindow: (() -> Void)? = nil,
        mcpActivityLog: MCPActivityLog? = nil,
        endpointPublisher: MCPEndpointPublisher? = nil,
        locationService: LocationService,
        fanControlService: FanControlService,
        updateController: UpdateController? = nil
    ) {
        self.store = store
        self.historyStore = historyStore
        self.onShowDebugWindow = onShowDebugWindow
        self.mcpActivityLog = mcpActivityLog
        self.endpointPublisher = endpointPublisher
        self.locationService = locationService
        self.fanControlService = fanControlService
        self.updateController = updateController
    }

    @State private var selectedPane: SettingsPane = .general

    @Environment(\.colorScheme) private var systemColorScheme

    private var palette: ThemePalette {
        ThemePalette(theme: store.resolvedTheme(), scheme: systemColorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(palette.separator)
                .frame(width: 1)
            detail
        }
        .frame(minWidth: 720, minHeight: 500)
        .environment(\.themePalette, palette)
        // One application covering all eleven panes. Every pane is
        // `.formStyle(.grouped)`, whose rows paint on `surface`, and
        // `.toggleStyle` rides the environment through the `switch`-based
        // pane dispatch below — so panes this branch must not edit
        // (`AIAccessPane`) are fixed without being opened.
        .themedToggles(on: .surface)
    }

    // MARK: - Sidebar

    /// The pane list, in three visual groups: appearance-and-layout,
    /// features-that-talk-to-things, and the escape hatch. Grouping is
    /// spacing-only — no headers, which would be chrome for nine rows —
    /// and lives in a switch so adding a `SettingsPane` case fails to
    /// compile until it's placed, rather than silently landing nowhere.
    private var paneGroups: [[SettingsPane]] {
        var groups: [[SettingsPane]] = [[], [], []]
        for pane in SettingsPane.allCases {
            switch pane {
            case .general, .modules, .menuBar, .theme:
                groups[0].append(pane)
            case .alerts, .fans, .aiAccess, .sync, .location:
                groups[1].append(pane)
            case .advanced, .about:
                groups[2].append(pane)
            }
        }
        return groups
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(paneGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group) { pane in
                        SettingsSidebarRow(
                            title: pane.title,
                            symbol: pane.symbol,
                            isSelected: pane == selectedPane
                        ) {
                            selectedPane = pane
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(width: 192, alignment: .top)
        .frame(maxHeight: .infinity)
        // Recessed relative to the detail column — the previous fill was
        // `surface`, which several dark themes render within a hair of
        // `background`, leaving the sidebar reading as a stranded strip of
        // the same wall (user feedback: "ugly and out of place"). A
        // scheme-aware scrim over the theme's own background guarantees
        // the two columns separate in every theme without inventing a new
        // theme token; translucent themes keep their material showing
        // through by thinning the base coat instead of the scrim.
        .background(
            ZStack {
                palette.background.opacity(palette.theme.useMaterialBackground ? 0.45 : 1)
                Color.black.opacity(systemColorScheme == .dark ? 0.16 : 0.04)
            }
        )
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedPane.title)
                    .font(palette.font(size: 20, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(selectedPane.subtitle)
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            content(for: selectedPane)
                // The grouped forms keep native controls but shed their
                // own system background so the theme's shows through.
                .scrollContentBackground(.hidden)
                // System Settings caps its form column; unbounded grouped
                // forms stretch sliders to absurd widths on a big window.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background)
    }

    // MARK: - Sidebar row

    /// One sidebar entry in the app's own list idiom: monochrome 13pt SF
    /// symbol, quiet `surfaceElevated` fill for the selected row (selection
    /// is a state — never accent, per the handoff), a fainter fill on
    /// hover. This replaces the colored System Settings icon chips.
    private struct SettingsSidebarRow: View {
        @Environment(\.themePalette) private var palette
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let title: String
        let symbol: String
        let isSelected: Bool
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                        .frame(width: 21)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(palette.font(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    // Selection is a state, never accent (unchanged rule) —
                    // but it has to *read* as a state: the fill alone
                    // vanished in themes where surfaceElevated sits close
                    // to the sidebar backdrop, so the selected pill also
                    // gets a hairline of the theme's separator.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected
                            ? palette.surfaceElevated
                            : (isHovered ? palette.surfaceElevated.opacity(0.5) : Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isSelected ? palette.separator : Color.clear, lineWidth: 1)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                    isHovered = hovering
                }
            }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralPane(store: store, updateController: updateController).formStyle(.grouped)
        case .modules:
            ModulesPane(store: store).formStyle(.grouped)
        case .menuBar:
            MenuBarPane(store: store).formStyle(.grouped)
        case .theme:
            ThemePane(store: store)
        case .alerts:
            AlertsPane(store: store, historyStore: historyStore).formStyle(.grouped)
        case .fans:
            FanControlPane(store: store, service: fanControlService).formStyle(.grouped)
        case .aiAccess:
            AIAccessPane(
                store: store,
                activityLog: mcpActivityLog,
                endpointPublisher: endpointPublisher
            ).formStyle(.grouped)
        case .sync:
            SyncPane(store: store).formStyle(.grouped)
        case .location:
            LocationPane(store: store, locationService: locationService).formStyle(.grouped)
        case .advanced:
            AdvancedPane(store: store, onShowDebugWindow: onShowDebugWindow).formStyle(.grouped)
        case .about:
            AboutPane().formStyle(.grouped)
        }
    }
}
