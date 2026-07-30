import SwiftUI
import MacStatKit

/// Tab 2 — History (plan §12.1: range selector, battery health trend, cycle
/// count over time, charge/discharge session list, per-metric history
/// browser). Placeholder only — real content is separate, parallel work.
/// Left here as a clearly labeled stub rather than omitted from the
/// `TabView` entirely, so the tab bar's four-tab shape matches the plan from
/// the start and the agent building this tab has a file to land content in
/// rather than needing to also wire up the tab itself.
struct HistoryTabView: View {
    var body: some View {
        StubTabContent(
            title: "History",
            systemImage: "chart.xyaxis.line",
            message: "Range selector, battery health trend, and per-metric history are built separately."
        )
    }
}
