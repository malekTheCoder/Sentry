import SwiftUI
import MacStatKit

/// The iPhone app's top-level navigation shell (plan §12.1's exact tab
/// order: Dashboard, History, Alerts, Settings). A plain `TabView` — the
/// plan's structure doesn't call for anything more elaborate (no nested
/// `NavigationStack` requirements specified per tab yet), and each tab view
/// owns whatever navigation it needs internally once its real content
/// lands.
///
/// **Theme propagation (plan §12.1's "Theme (shares Theme tokens with the
/// Mac app)," built out by the Settings tab).** Before the Settings tab
/// existed, `DashboardTabView` computed its own `ThemePalette` locally and
/// hardcoded `.terminal` — its own doc comment said outright "No theme
/// picker exists yet on this platform." Now that one does, the selection
/// has to reach every tab, not just Dashboard, so it's read and resolved
/// once here, at the one view that is an ancestor of all four tabs, and
/// pushed down via `.environment(\.themePalette:)`. `PlaceholderCard`
/// (`Dashboard/DashboardTabView.swift`) already reads `\.themePalette` from
/// the environment rather than being passed one explicitly, so this is
/// exactly the mechanism the codebase already expected a theme source to
/// use — it just had nothing upstream setting it to anything but the
/// environment's default (`Theme.terminal`, dark) before now.
///
/// **Why the `@AppStorage` key is duplicated here and in
/// `Settings/SettingsTabView.swift` rather than sharing a constant.** Both
/// need to read/write the exact same `UserDefaults` key (`"selectedThemeID"`)
/// for `@AppStorage` to keep them in sync — SwiftUI's `@AppStorage`
/// resolves by string key against the default suite, not by any shared
/// Swift symbol. A shared constant would be the cleaner fix, but every
/// existing candidate file for it (`Theme/ThemeColor+SwiftUI.swift`,
/// `MacStatKit`) sits outside this task's `MacStatMobile/Settings/` +
/// `RootTabView.swift`/`MacStatMobileApp.swift` boundary with three other
/// agents concurrently building neighboring tabs — introducing a new shared
/// symbol elsewhere is a bigger footprint than this task's theme-plumbing
/// mandate calls for. The literal must simply match in both places; if it
/// ever drifts, the fix is one file, not an architectural one.
struct RootTabView: View {
    /// Persisted locally on this phone only — see `SettingsTabView`'s theme
    /// section doc comment for why this is deliberately not synced to the
    /// Mac (no sync channel exists to carry it).
    @AppStorage("selectedThemeID") private var selectedThemeID: String = Theme.slate.id
    @Environment(\.colorScheme) private var systemColorScheme

    private var palette: ThemePalette {
        let theme = Theme.builtInPresets.first { $0.id == selectedThemeID } ?? .slate
        return ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    var body: some View {
        TabView {
            DashboardTabView()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent") }

            HistoryTabView()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }

            AlertsTabView()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }

            SettingsTabView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .environment(\.themePalette, palette)
    }
}

// MARK: - StubTabContent

/// Shared "this tab isn't built yet" content for History/Alerts/Settings —
/// factored out so the three stubs stay visually and texturally identical
/// (one place to change the stub's look, not three) and so whichever agent
/// replaces each stub is working against a small, obviously-temporary file
/// rather than something that could be mistaken for finished UI.
struct StubTabContent: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}
