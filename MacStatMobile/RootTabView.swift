import SwiftUI
import MacStatKit

/// The iPhone app's top-level navigation shell (plan §12.1's exact tab
/// order: Dashboard, History, Alerts, Settings). A plain `TabView` — the
/// plan's structure doesn't call for anything more elaborate (no nested
/// `NavigationStack` requirements specified per tab yet), and each tab view
/// owns whatever navigation it needs internally once its real content
/// lands.
struct RootTabView: View {
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
