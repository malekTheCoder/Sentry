import SentryKit
import SwiftUI
import WidgetKit

// MARK: - ComplicationView: family dispatch

/// Routes to a family-appropriate rendering by `\.widgetFamily`, matching
/// `SentryWidgetEntryView`'s dispatch pattern on iOS
/// (`SentryWidget/SentryWidgetBundle.swift`). Complication families are
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
            // complication doesn't declare (`SentryWatchWidget.families`
            // below), but "no data" is the honest response if a future
            // watchOS ever does, matching `SentryWidgetEntryView`'s
            // precedent exactly.
            InlineComplicationView(snapshot: entry.snapshot)
        }
    }
}

// MARK: - Battery/CPU hero swap, shared by every family below

/// The battery/CPU swap every family view needs, factored out once rather
/// than reimplemented per family. Mirrors `OverviewPage.HeroReadout`
/// (`SentryWatch/Pages/OverviewPage.swift`) exactly: when
/// `WatchRelaySnapshot.showsBattery` is `false` (a Mac mini/Studio/Pro that
/// genuinely reported no battery), the headline metric swaps to CPU rather
/// than rendering the fake `0%` `WatchRelayManager` used to fill
/// `batteryPercent` with on those Macs — the bug this type exists to close.
///
/// `symbol` stays the subject's icon (`battery.100`/`bolt.fill` or `cpu`)
/// even when `percent` is `nil`, matching `OverviewPage.HeroReadout
/// .heroSymbol`'s convention: the icon names *what* is being shown, the text
/// is what says whether a value actually arrived.
private struct ComplicationHero {
    let subject: String
    let percent: Double?
    let symbol: String

    init(_ snapshot: WatchRelaySnapshot) {
        if snapshot.showsBattery {
            subject = "Battery"
            percent = snapshot.batteryPercent
            symbol = snapshot.isCharging ? "bolt.fill" : "battery.100"
        } else {
            subject = "CPU"
            percent = snapshot.cpuPercent
            symbol = "cpu"
        }
    }
}

/// "38" or "--" — no `%` suffix, since every call site below supplies that
/// context itself (a `Gauge`'s current-value label, or text that appends its
/// own "%"). Missing or non-finite renders as the placeholder, never as a
/// rounded `0` — the same "absence is not zero" rule as everywhere else in
/// this codebase, just without `WatchFormatting` to reach for:
/// `SentryWatchWidgetExtension` only compiles `SentryKit_watchOS` (see
/// `project.yml`), not the `SentryWatch` app target that type lives in.
private func complicationPercentText(_ percent: Double?) -> String {
    guard let percent, percent.isFinite else { return "--" }
    return "\(Int(percent.rounded()))"
}

/// A `Gauge`'s `value` needs *some* finite number in range even when there is
/// nothing to show — clamped to 0 for a missing/non-finite reading. The
/// accompanying label always renders from `complicationPercentText`, which is
/// what actually carries "no data" honestly; this just keeps the gauge from
/// being handed `nil` or a wild value.
private func complicationGaugeValue(_ percent: Double?) -> Double {
    guard let percent, percent.isFinite else { return 0 }
    return min(max(percent, 0), 100)
}

/// Whether `snapshot`'s reading is old enough that a family with no room for
/// `FreshnessBadge`'s full label should show some cue anyway. See
/// `Freshness.warrantsCompactStalenessCue` for the threshold and why it
/// isn't simply "not `.live`".
private func isCompactStale(_ snapshot: WatchRelaySnapshot) -> Bool {
    Freshness(lastSeen: snapshot.lastSeen).warrantsCompactStalenessCue
}

// MARK: - accessoryCircular

/// Battery-or-CPU gauge — the Watch's exact equivalent of
/// `AccessoryCircularWidgetView` on iOS (`SentryWidget/Views/AccessoryWidgetViews.swift`),
/// same `Gauge`/`.accessoryCircular` reasoning: the system's own tinted/
/// vibrant rendering on the watch face, not a hand-drawn arc.
///
/// **Staleness cue.** This family has no room for `FreshnessBadge`'s label,
/// so a stale reading (`Freshness.warrantsCompactStalenessCue`) instead dims
/// the whole gauge — a reading that quietly stopped updating hours ago
/// should not look as confident as one from thirty seconds ago.
struct CircularComplicationView: View {
    let snapshot: WatchRelaySnapshot?

    var body: some View {
        if let snapshot {
            let hero = ComplicationHero(snapshot)
            Gauge(value: complicationGaugeValue(hero.percent), in: 0...100) {
                Image(systemName: hero.symbol)
            } currentValueLabel: {
                Text(complicationPercentText(hero.percent))
            }
            .gaugeStyle(.accessoryCircular)
            .opacity(isCompactStale(snapshot) ? 0.55 : 1.0)
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

/// Device name + battery-or-CPU/charging line + a `Freshness`-derived
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

    /// On a Mac that reported no battery, this swaps to CPU rather than
    /// printing the fake `0%` `batteryPercent` used to carry — see
    /// `ComplicationHero`'s doc comment. This family has room for a label,
    /// unlike the other three, so the swap says "CPU" outright rather than
    /// leaning on an icon alone.
    private func statLine(_ snapshot: WatchRelaySnapshot) -> String {
        let hero = ComplicationHero(snapshot)
        var parts = [String]()
        if snapshot.showsBattery {
            parts.append("\(complicationPercentText(hero.percent))%")
            if snapshot.isCharging {
                parts.append("Charging")
            }
        } else {
            parts.append("CPU \(complicationPercentText(hero.percent))%")
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
///
/// **Staleness cue.** There is no room here for a label or a dimmable
/// container — the whole view is one line of system-rendered text with no
/// background to apply opacity against. So a stale reading appends a single
/// trailing glyph (`⋯`) instead: the smallest change that still reads as
/// "this is not a fresh number" per `Freshness.warrantsCompactStalenessCue`.
struct InlineComplicationView: View {
    let snapshot: WatchRelaySnapshot?

    var body: some View {
        if let snapshot {
            let hero = ComplicationHero(snapshot)
            let subject = snapshot.showsBattery ? "Mac" : "Mac CPU"
            let chargeMark = (snapshot.showsBattery && snapshot.isCharging) ? " ⚡︎" : ""
            let staleMark = isCompactStale(snapshot) ? " ⋯" : ""
            Text("\(subject) \(complicationPercentText(hero.percent))%\(chargeMark)\(staleMark)")
        } else {
            Text("Mac --")
        }
    }
}

// MARK: - accessoryCorner

/// The corner complication slot (Modular/Utility-style faces) — a compact
/// gauge, same reasoning as `CircularComplicationView` but styled for the
/// corner's curved presentation.
///
/// **Staleness cue.** Same dimming treatment as `CircularComplicationView`,
/// for the same reason — this family has no room for a freshness label
/// either.
struct CornerComplicationView: View {
    let snapshot: WatchRelaySnapshot?

    var body: some View {
        if let snapshot {
            let hero = ComplicationHero(snapshot)
            Gauge(value: complicationGaugeValue(hero.percent), in: 0...100) {
                Text("\(complicationPercentText(hero.percent))%")
            }
            .gaugeStyle(.accessoryCircular)
            .opacity(isCompactStale(snapshot) ? 0.55 : 1.0)
            .widgetLabel {
                Text(snapshot.showsBattery && snapshot.isCharging ? String(localized: "Charging") : String(localized: "Mac"))
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
