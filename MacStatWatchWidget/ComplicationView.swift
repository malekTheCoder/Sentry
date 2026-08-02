import MacStatKit
import SwiftUI
import WidgetKit

// MARK: - ComplicationView: family dispatch

/// Routes to a family-appropriate rendering by `\.widgetFamily`, matching
/// `MacStatWidgetEntryView`'s dispatch pattern on iOS
/// (`MacStatWidget/MacStatWidgetBundle.swift`). Complication families are
/// smaller and more numerous than the iOS home-screen families, but the
/// same "one place any family's data can be wrong" reasoning applies: every
/// case below reads `entry.snapshot`, never re-derives anything from
/// `WatchRelayStore` itself.
struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        familyView
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var familyView: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(snapshot: entry.snapshot)
        case .accessoryRectangular:
            RectangularComplicationView(snapshot: entry.snapshot)
        case .accessoryInline:
            InlineComplicationView(snapshot: entry.snapshot)
        case .accessoryCorner:
            CornerComplicationView(snapshot: entry.snapshot)
        default:
            // A non-frozen-from-our-side enum needs an exhaustive
            // fallback — WidgetKit shouldn't ever request a family this
            // complication doesn't declare (`MacStatWatchWidget.families`
            // below), but "no data" is the honest response if a future
            // watchOS ever does, matching `MacStatWidgetEntryView`'s
            // precedent exactly.
            InlineComplicationView(snapshot: entry.snapshot)
        }
    }
}

// MARK: - accessoryCircular

/// Battery-percent gauge — the Watch's exact equivalent of
/// `AccessoryCircularWidgetView` on iOS (`MacStatWidget/Views/AccessoryWidgetViews.swift`),
/// same `Gauge`/`.accessoryCircular` reasoning: the system's own tinted/
/// vibrant rendering on the watch face, not a hand-drawn arc.
struct CircularComplicationView: View {
    let snapshot: WatchRelaySnapshot?

    var body: some View {
        if let snapshot {
            Gauge(value: min(max(snapshot.batteryPercent, 0), 100), in: 0...100) {
                Image(systemName: snapshot.isCharging ? "bolt.fill" : "battery.100")
            } currentValueLabel: {
                Text("\(Int(snapshot.batteryPercent.rounded()))")
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            Gauge(value: 0, in: 0...100) {
                Image(systemName: "questionmark")
            } currentValueLabel: {
                Text("--")
            }
            .gaugeStyle(.accessoryCircular)
        }
    }
}

// MARK: - accessoryRectangular

/// Device name + battery/charging/thermal line + a `Freshness`-derived
/// staleness label — the one complication family with enough room to be
/// honest about *how* old the reading is, not just what it is, matching
/// this codebase's `FreshnessBadge` discipline (see that type's doc
/// comment) even in a surface with no room for the full badge view.
struct RectangularComplicationView: View {
    let snapshot: WatchRelaySnapshot?

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.deviceName)
                    .font(.headline)
                    .lineLimit(1)
                Text(statLine(snapshot))
                    .font(.caption2)
                    .lineLimit(1)
                Text(footerLine(snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sentry")
                    .font(.headline)
                Text("No data yet")
                    .font(.caption2)
            }
        }
    }

    private func statLine(_ snapshot: WatchRelaySnapshot) -> String {
        var parts = ["\(Int(snapshot.batteryPercent.rounded()))%"]
        if snapshot.isCharging {
            parts.append("Charging")
        }
        return parts.joined(separator: " · ")
    }

    /// Staleness label, plus the demo-data disclosure
    /// `WatchRelaySnapshot.sourceIsDemoData` exists to carry (see that
    /// field's doc comment: a complication pinned to a watch face has no
    /// companion banner to disclose fabricated data any other way). This is
    /// the one complication family with room for it — the same reasoning
    /// `WidgetDemoDataCaption` applies on iOS by living only in
    /// `.systemLarge`.
    private func footerLine(_ snapshot: WatchRelaySnapshot) -> String {
        let freshness = Freshness(lastSeen: snapshot.lastSeen).label(lastSeen: snapshot.lastSeen)
        return snapshot.sourceIsDemoData ? "\(freshness) · Demo" : freshness
    }
}

// MARK: - accessoryInline

/// One line of text next to the time on a watch face's inline slot —
/// deliberately the terser of the two text-based renderings, matching how
/// little horizontal room this family actually has.
struct InlineComplicationView: View {
    let snapshot: WatchRelaySnapshot?

    var body: some View {
        if let snapshot {
            Text("Mac \(Int(snapshot.batteryPercent.rounded()))%\(snapshot.isCharging ? " ⚡︎" : "")")
        } else {
            Text("Mac --")
        }
    }
}

// MARK: - accessoryCorner

/// The corner complication slot (Modular/Utility-style faces) — a compact
/// gauge, same reasoning as `CircularComplicationView` but styled for the
/// corner's curved presentation.
struct CornerComplicationView: View {
    let snapshot: WatchRelaySnapshot?

    var body: some View {
        if let snapshot {
            Gauge(value: min(max(snapshot.batteryPercent, 0), 100), in: 0...100) {
                Text("\(Int(snapshot.batteryPercent.rounded()))%")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetLabel {
                Text(snapshot.isCharging ? String(localized: "Charging") : String(localized: "Mac"))
            }
        } else {
            Gauge(value: 0, in: 0...100) {
                Text("--")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetLabel {
                Text("Mac")
            }
        }
    }
}
