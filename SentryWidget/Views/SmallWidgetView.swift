import AppIntents
import SentryKit
import SwiftUI

/// `.systemSmall` — plan §12.3: "Battery arc + % + charging W, freshness
/// dot." The most space-constrained home screen family, so this shows
/// exactly the four things the spec lists and nothing else — no device
/// name, no demo-data caption (see `WidgetDemoDataCaption`'s doc comment on
/// where that disclosure lives instead for this family) — plus one
/// interactive control: a refresh button, the smallest family this widget
/// declares so also the one most likely to be pinned somewhere a user
/// checks often enough to want a manual nudge rather than waiting out
/// `WidgetTimelineScheduler`'s cadence.
struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            VStack(spacing: 6) {
                BatteryArcView(percent: snapshot.batteryPercent, isCharging: snapshot.isCharging)
                    .frame(width: 64, height: 64)
                wattsLabel(snapshot)
                HStack(spacing: 4) {
                    freshnessDot(snapshot)
                    refreshButton
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WidgetNoDataView()
        }
    }

    /// `Button(intent:)` — the iOS 17+/macOS 14+ interactive-widget API:
    /// tapping this runs `WidgetRefreshIntent.perform()` (see that type's
    /// doc comment for why it's a local duplicate of `RefreshWidgetIntent`
    /// rather than a shared reference) directly in the widget extension
    /// process, in place, with no navigation to the containing app the way
    /// a widget's `Link`/`widgetURL` would require.
    ///
    /// `.plain` rather than the default button style: WidgetKit renders
    /// system button chrome (background capsule, tint) around any style
    /// that asks for one, which would compete with `BatteryArcView` and
    /// the freshness dot for visual weight in a family this constrained —
    /// plain keeps this to just the glyph, matching the freshness dot's
    /// own bare-shape treatment right next to it. `Image(systemName:)`
    /// resolves as an SF Symbol, not text, so `.dynamicTypeSize` scaling
    /// doesn't apply in the way it does to `wattsLabel`'s `Text` below —
    /// its screen size instead tracks the `.font` modifier the same way
    /// every symbol in this file already does (see `wattsLabel`/
    /// `freshnessDot`), so no separate Dynamic Type accommodation is
    /// needed here beyond the `.caption2` this already matches.
    private var refreshButton: some View {
        Button(intent: WidgetRefreshIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Refresh"))
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
