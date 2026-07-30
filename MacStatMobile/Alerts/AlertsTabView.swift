import SwiftUI
import MacStatKit

/// Tab 3 — Alerts (plan §12.1: recent alert feed, rule enable/disable —
/// full rule editing stays on the Mac for v2). Placeholder only; see
/// `HistoryTabView`'s doc comment for why the stub exists rather than an
/// omitted tab.
struct AlertsTabView: View {
    var body: some View {
        StubTabContent(
            title: "Alerts",
            systemImage: "bell.badge",
            message: "The alert feed and rule enable/disable toggles are built separately."
        )
    }
}
