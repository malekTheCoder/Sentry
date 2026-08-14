import SentryKit
import SwiftUI

/// The battery-arc glyph every non-accessory family (`.systemSmall`,
/// `.systemMedium`, `.systemLarge`) uses per plan §12.3's spec table. A
/// single shared view rather than three near-identical `Circle().trim`
/// blocks, so the arc's look (stroke width proportional to its own frame,
/// charging color) can't drift between families independently.
///
/// **Why not `Gauge`.** `Gauge(value:in:)` with a circular style is exactly
/// right for the *lock screen accessory* families (see
/// `AccessoryWidgetViews.swift`) — `.accessoryCircular` is specifically
/// designed to render `Gauge` in the system's own tinted/monochrome lock
/// screen rendering modes. Home screen widgets don't get that treatment
/// (full color, no tint constraint), and plan §12.3's spec — "battery arc +
/// % + charging W" — reads as a custom glyph with the percentage as its own
/// prominent text, which a `Gauge`'s built-in label layout doesn't give
/// direct control over at small sizes. A hand-drawn arc keeps that control.
struct BatteryArcView: View {
    let percent: Double
    let isCharging: Bool
    var lineWidth: CGFloat = 6
    var showsPercentText: Bool = true

    private var clampedFraction: Double {
        min(max(percent / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clampedFraction)
                .stroke(arcColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsPercentText {
                VStack(spacing: 0) {
                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Green above 20%, red at/below — matches iOS's own low-battery
    /// convention (Settings/status bar) so this glyph reads consistently
    /// with the rest of the system rather than introducing its own scale.
    private var arcColor: Color {
        if isCharging { return .green }
        return percent <= 20 ? .red : .green
    }
}

// MARK: - Shared "no data yet" state

/// What every family renders when `WidgetSnapshotStore.read()` returned
/// `nil` — no `MockDataSource` tick has reached the App Group cache yet
/// (freshly installed widget, or the phone app hasn't been opened this
/// install). Deliberately not a fabricated-looking "0%" battery: that would
/// be the exact "0 pending reads as caught-up" failure mode `SyncPane`'s
/// doc comment (`Sentry/Settings/Panes/SyncPane.swift`) already named and
/// ruled out on the Mac side. Honest absence instead.
struct WidgetNoDataView: View {
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "questionmark.circle")
                .font(compact ? .title3 : .title2)
                .foregroundStyle(.secondary)
            if !compact {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Open Sentry")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared demo-data caption

/// The `.systemLarge` caption plan honesty requires (see the task that
/// produced this widget, and the phone app's `DemoDataBanner` precedent) —
/// only `.systemLarge` has room for a full sentence. The smaller home
/// screen families carry `WidgetDemoDataTag` below instead: the gallery's
/// configuration description (`SentryWidgetBundle.swift`) discloses demo
/// data at add-time, but a widget sits on the home screen long after
/// add-time, and a screenshot of it carries no gallery text — the marker
/// has to travel with the data, the same rule `WidgetSnapshot
/// .sourceIsDemoData` exists to serve.
struct WidgetDemoDataCaption: View {
    var body: some View {
        Label {
            Text("Demo data — no live Mac sync yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "wand.and.stars")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// The compact demo marker for `.systemSmall` and `.systemMedium` — the
/// families with no room for `WidgetDemoDataCaption`'s full sentence. Same
/// glyph as that caption and as the phone app's own banner and tags
/// (`DemoDataDisclosure.symbolName` is `wand.and.stars`; not imported here
/// because a widget extension can't depend on its containing app's target),
/// so one symbol means "synthesized data" everywhere a user can meet it.
/// The word is spelled out too — §9.4's standing rule that state is never
/// carried by a glyph or hue alone — and VoiceOver gets the caption's full
/// sentence rather than the pill's abbreviation.
struct WidgetDemoDataTag: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 7, weight: .semibold))
            Text("Demo")
                .font(.system(size: 7.5, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Demo data — no live Mac sync yet"))
    }
}
