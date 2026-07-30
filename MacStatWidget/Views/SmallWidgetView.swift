import MacStatKit
import SwiftUI

/// `.systemSmall` — plan §12.3: "Battery arc + % + charging W, freshness
/// dot." The most space-constrained home screen family, so this shows
/// exactly the four things the spec lists and nothing else — no device
/// name, no demo-data caption (see `WidgetDemoDataCaption`'s doc comment on
/// where that disclosure lives instead for this family).
struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            VStack(spacing: 6) {
                BatteryArcView(percent: snapshot.batteryPercent, isCharging: snapshot.isCharging)
                    .frame(width: 64, height: 64)
                wattsLabel(snapshot)
                freshnessDot(snapshot)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WidgetNoDataView()
        }
    }

    @ViewBuilder
    private func wattsLabel(_ snapshot: WidgetSnapshot) -> some View {
        if snapshot.isCharging, let watts = snapshot.chargingWatts {
            Text("\(Int(watts.rounded()))W")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// A bare colored dot rather than the full `FreshnessBadge` (label text
    /// wouldn't fit legibly at this size) — same tier colors, same
    /// underlying `Freshness` computation, just without the text half of
    /// `FreshnessBadge`'s label. Accessible via
    /// `.accessibilityLabel` so VoiceOver still gets the words a sighted
    /// user would infer from `FreshnessBadge` elsewhere in the app.
    private func freshnessDot(_ snapshot: WidgetSnapshot) -> some View {
        let freshness = Freshness(lastSeen: snapshot.lastSeen)
        let color: Color
        switch freshness {
        case .live: color = .green
        case .recent: color = .orange
        case .stale, .asleep: color = .secondary
        }
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityLabel(freshness.label(lastSeen: snapshot.lastSeen))
    }
}
