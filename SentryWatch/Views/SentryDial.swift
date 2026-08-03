import SentryKit
import SwiftUI
#if canImport(WatchKit)
import WatchKit
#endif

// MARK: - SentryDial: the app icon's gauge, as a view

/// A 270° open-bottom arc gauge — the Sentry icon's own geometry, rendered as
/// a readout.
///
/// **Why the watch app grew a radial language at all.** Sentry's icon
/// (`docs/icon/sentry-icon-source.svg`) is a dial: a sweep of amber around a
/// circular well, gap at the bottom, needle in the middle. Every other surface
/// of this app is a table or a chart, which is correct for a Mac window and a
/// phone screen. The watch was the same flat left-aligned list of labels and
/// straight progress bars, which made it the one screen that looked like
/// nothing in particular — and it was also the one platform whose *native*
/// vocabulary is radial. watchOS ships `Gauge`'s `.accessoryCircular` styles
/// for exactly this, the Activity rings taught every user on the platform to
/// read a partial arc as a proportion, and the brand was already that shape.
/// So the arc is not decoration bolted onto a list; it is the readout, and the
/// list is what it replaces.
///
/// **Why this is hand-rolled instead of `Gauge(value:in:)` with
/// `.gaugeStyle(.accessoryCircular)`.** That was the first attempt and it
/// fails on the one requirement that is not negotiable in this codebase.
///
/// 1. *`Gauge` cannot say "not reported."* It takes a non-Optional
///    `BinaryFloatingPoint`. There is no value to hand it for a Mac that did
///    not report CPU, and every candidate is a lie: `0` draws an empty ring
///    that reads as a genuine zero, and the whole reason `MetricTile` below
///    drew no bar at all for a missing metric is that an empty track is
///    indistinguishable from a real zero. This type takes `fraction: Double?`
///    and renders `nil` as a *dotted* track with no fill and no needle —
///    a mark that cannot be read as a measurement of zero because it is
///    visibly not a measurement track. (The dotted ring is also on-brand: the
///    icon's collar is a dashed ring.) See `notReported` below.
/// 2. *The built-in styles are complication-sized.* `.accessoryCircular`
///    renders at a fixed system metric intended for a widget slot; growing it
///    to hero size means `scaleEffect`, which scales the stroke and the centre
///    text together and produces a fat ring around blurry digits.
/// 3. *The icon's sweep is a specific 270°.* The system styles pick their own.
///
/// The cost of hand-rolling is that this view does not inherit `Gauge`'s
/// automatic accessibility. That is paid explicitly: every caller wraps the
/// dial in an `accessibilityElement(children: .combine)` with a spoken label
/// that states the value *and*, when it matters, a severity word — see
/// `MetricSeverity.accessibilityWord`.
///
/// **Dynamic Type.** This view deliberately has no Dynamic Type behaviour of
/// its own: it is a fixed-aspect shape, and a shape that grows with text
/// settings would push everything below it off a 40mm screen. The adaptation
/// happens one level up instead — `OverviewPage` stops drawing dials entirely
/// at accessibility text sizes and falls back to the flat, full-width,
/// text-forward layout, which is genuinely better at those sizes. A radial
/// gauge whose label has been scaled to 40% to fit inside a ring is worse than
/// a plain row, and that failure mode is the reason for the branch rather than
/// a `minimumScaleFactor` deep enough to hide it.
struct SentryDial<Center: View>: View {
    /// `0...1`, or `nil` for "the Mac did not report this." Values outside the
    /// range are clamped *for the arc only* — the caller still prints the raw
    /// number, on the same reasoning `MetricTile.fraction` documents: an arc
    /// longer than its track is a rendering artefact, but a 103% clamped to
    /// 100 in the text would hide a collector bug behind a plausible number.
    let fraction: Double?

    /// The arc's colour. Callers pass a metric identity colour at normal
    /// severity and a severity colour above it — see `MetricSeverity.tint`.
    let tint: Color

    /// Stroke weight in points. Not derived from the frame: the hero dial and
    /// the metric dials want visually similar weights at very different
    /// diameters, and a proportional stroke makes the small ones look like
    /// thread.
    let lineWidth: CGFloat

    /// Whatever sits in the well — a value, a glyph, an em dash. Rendered
    /// unrotated, inset clear of the stroke.
    @ViewBuilder let center: () -> Center

    /// 0.75 of a turn = 270°, with the missing quarter centred on 6 o'clock
    /// after the rotation below. This is the icon's arc, measured off
    /// `sentry-icon-source.svg`, not a round number picked for convenience.
    private static var sweep: Double { 0.75 }

    /// Puts the gap at the bottom. `trim` starts at 3 o'clock and runs
    /// clockwise, so 270° of it ends at 12 o'clock; rotating by 135° moves the
    /// span to 7:30 → 4:30 and centres the opening on 6 o'clock.
    private static var gapRotation: Double { 135 }

    var body: some View {
        ZStack {
            if let fraction {
                arc(to: Self.sweep)
                    .stroke(.tertiary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                arc(to: Self.sweep * min(max(fraction, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            } else {
                notReported
            }
        }
        .rotationEffect(.degrees(Self.gapRotation))
        // Applied *after* the rotation so the well's contents stay upright.
        .overlay {
            center()
                .padding(lineWidth * 1.6)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arc(to end: Double) -> some Shape {
        Circle().trim(from: 0, to: end)
    }

    /// The "we were not told" mark. A dotted track, no fill, no tint — it
    /// occupies the same space as a real reading so the layout does not shift
    /// between a Mac that reported a metric and one that didn't, but it is
    /// visibly not a measurement. This is the single most important line in
    /// this file: the alternative that the honesty rules forbid is a solid
    /// track with a zero-length fill, which is pixel-identical to a genuine
    /// 0%.
    private var notReported: some View {
        arc(to: Self.sweep)
            .stroke(
                .tertiary,
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    // Dot-and-gap rather than a long dash: a dashed ring at
                    // this diameter reads as a segmented gauge (Activity's
                    // "move goal" ticks), which is a measurement. Round dots
                    // spaced wider than they are wide read as absence.
                    dash: [0.5, lineWidth * 2]
                )
            )
    }
}

// MARK: - WatchFace

/// How much smaller (or larger) this watch is than the face the dial sizes
/// were tuned on.
///
/// **Why this is needed at all.** A dial is the one element on these pages
/// with a hard, non-negotiable size: text reflows, wraps and scales, but a
/// ring is a fixed square of screen. The supported range is 40mm (162pt wide)
/// to 49mm Ultra (~205pt) — a 27% span — and a single hardcoded diameter
/// cannot serve both ends. Tuned on the 46mm face, the hero dial pushed the
/// thermal chip off the bottom of a 40mm one at rest, which is the exact
/// regression `OverviewPage`'s spacing comment and `StatusChips`' arrangement
/// comment were both written to prevent. Tuned on the 40mm face instead, the
/// Ultra would render a wristwatch-sized instrument in the middle of a
/// billboard.
///
/// **Why `screenBounds` and not a `GeometryReader`.** A `GeometryReader` here
/// would report the width of the slot the dial is *already* in — which is a
/// third of a row, for the metric dials — not the size of the face, and it
/// would make the dial's size depend on a layout pass that its own size feeds
/// into. `WKInterfaceDevice.screenBounds` is the platform's own answer to
/// "how big is this watch", it is a constant for the life of the process, and
/// it is what the dial actually wants to know.
///
/// **Why the clamp.** The scale is a proportion of screen width, but the
/// constraint being managed is *vertical* — how much room is left for the
/// status chips underneath. Width and height happen to track each other
/// closely across the current lineup (every face is very near 1:1.22), but
/// clamping to ±15% means a future face with a different aspect ratio, or a
/// display mode this code has never seen, degrades to a slightly-off dial
/// rather than to one that has eaten the chips.
enum WatchFace {
    /// The 46mm Series 10/11 face, in points — the one every dial diameter in
    /// this app was measured against on the simulator.
    private static let referenceWidth: CGFloat = 198

    static let scale: CGFloat = {
        #if canImport(WatchKit)
        let width = WKInterfaceDevice.current().screenBounds.width
        guard width > 0 else { return 1 }
        return min(max(width / referenceWidth, 0.82), 1.15)
        #else
        return 1
        #endif
    }()
}

// MARK: - MetricSeverity

/// How alarmed the screen should be about one metric.
///
/// **Why this exists.** Before this, CPU 37% and CPU 97% rendered identically
/// — same weight, same colour, same everything — and the only thing carrying
/// any hue was the fill bar's fixed identity colour, which said "this row is
/// CPU," not "this number is a problem." A remote machine is exactly the case
/// where the number's *meaning* has to survive a two-second glance, because
/// the user cannot look at the machine to check.
///
/// **Why thresholds are per-metric and not one shared pair of numbers.** A
/// single "90% is bad" rule would be wrong in both directions here, and wrong
/// in the more dangerous direction for the metric people already misread:
///
/// - **Memory takes its severity from `memoryPressure`, never from
///   `memoryUsedPercent`.** `WatchRelaySnapshot.memoryUsedPercent`'s own doc
///   comment states the reason at length — on macOS a high used-percent is
///   normal and usually harmless, because the kernel holds cached file pages
///   until something else wants the RAM. Painting MEM 94% red would contradict
///   the codebase's documented position and would train users to panic at the
///   healthiest number on the screen. Pressure is the field that says whether
///   the percentage is a problem, so pressure is what colours it. A Mac that
///   reported a percentage but no pressure gets no severity at all, which is
///   the honest answer: we have the number and not the thing that interprets
///   it.
/// - **Disk is the one where a high percentage genuinely is the problem.** A
///   boot volume at 97% stops taking snapshots and starts failing saves. It
///   gets the tightest thresholds.
/// - **CPU is loud but rarely broken.** 95% is what a render looks like, so it
///   escalates later than disk and its spoken word is "busy," not "critical" —
///   the colour says look, the word says what at.
/// - **Battery escalates downward**, and not at all while charging: 8% on the
///   charger is a Mac that is fine.
///
/// **Colour is never the only carrier.** Every non-normal severity supplies a
/// `symbol` drawn next to the metric's label and an `accessibilityWord` folded
/// into the spoken label. That is this codebase's standing rule for the Mac
/// app and it applies with more force on a wrist read in direct sunlight,
/// where hue is the first thing to go.
enum MetricSeverity {
    case normal
    case elevated
    case high

    /// `nil` at normal severity, so the caller keeps the metric's own identity
    /// colour (CPU blue, memory purple, disk teal) rather than being forced to
    /// a neutral by this type.
    var tint: Color? {
        switch self {
        case .normal: return nil
        case .elevated: return .orange
        case .high: return .red
        }
    }

    /// The non-colour carrier. Absent at normal severity — a glyph on every
    /// tile all the time would stop meaning anything.
    var symbol: String? {
        switch self {
        case .normal: return nil
        case .elevated: return "exclamationmark"
        case .high: return "exclamationmark.triangle.fill"
        }
    }

    /// Appended to the spoken label, so VoiceOver conveys the same escalation
    /// the colour does. The words are supplied per metric by the callers below
    /// rather than being generic ("elevated"/"high"), because "disk nearly
    /// full" and "CPU busy" are the sentences a user can act on.
    func accessibilityWord(elevated: String, high: String) -> String? {
        switch self {
        case .normal: return nil
        case .elevated: return elevated
        case .high: return high
        }
    }

    // MARK: Per-metric derivations

    /// ≥85 busy, ≥95 pinned. Deliberately later than disk's: a Mac at 90% is
    /// usually a Mac doing its job, and a screen that shouts at every export
    /// gets ignored by the time it matters.
    static func cpu(_ percent: Double?) -> MetricSeverity {
        guard let percent, percent.isFinite else { return .normal }
        if percent >= 95 { return .high }
        if percent >= 85 { return .elevated }
        return .normal
    }

    /// **From pressure only.** See this type's header: the percentage is the
    /// most misinterpretable number in the payload and must not drive colour.
    /// `nil` pressure (an old phone, or a Mac that reported no memory module)
    /// is `.normal` rather than a guess — the MEM dial still shows whatever
    /// percentage it has, uncoloured, which is exactly what the watch knows.
    static func memory(_ pressure: MemoryPressureSummary?) -> MetricSeverity {
        switch pressure {
        case .critical: return .high
        case .warning: return .elevated
        // `.unknown` means a newer phone named a tier this build can't. That
        // is surfaced as its own status chip (`StatusChips`), which says so in
        // words; inventing a severity for it here would be this file guessing
        // at a meaning it explicitly does not have.
        case .normal, .unknown, .none: return .normal
        }
    }

    /// ≥90 nearly full, ≥95 critically full. The tightest thresholds here
    /// because this is the only metric whose high value is unambiguously bad
    /// and the only one nothing else in the user's day surfaces until it
    /// already broke something.
    static func disk(_ percent: Double?) -> MetricSeverity {
        guard let percent, percent.isFinite else { return .normal }
        if percent >= 95 { return .high }
        if percent >= 90 { return .elevated }
        return .normal
    }

    /// Escalates *downward*, and is suppressed entirely while charging — a Mac
    /// at 8% on the charger is a Mac that is fine, and colouring it red would
    /// be alarming the user about a situation that is actively resolving.
    static func battery(percent: Double?, isCharging: Bool) -> MetricSeverity {
        guard !isCharging, let percent, percent.isFinite else { return .normal }
        if percent <= 10 { return .high }
        if percent <= 20 { return .elevated }
        return .normal
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Dial states") {
    HStack(spacing: 8) {
        SentryDial(fraction: 0.68, tint: .primary, lineWidth: 5) {
            Text("68%").font(.caption2).minimumScaleFactor(0.5).lineLimit(1)
        }
        SentryDial(fraction: 0.97, tint: .red, lineWidth: 5) {
            Text("97%").font(.caption2).minimumScaleFactor(0.5).lineLimit(1)
        }
        // The case the whole type exists for: not reported, which must not
        // look like a zero.
        SentryDial(fraction: nil, tint: .primary, lineWidth: 5) {
            Text("—").font(.caption2)
        }
        SentryDial(fraction: 0, tint: .teal, lineWidth: 5) {
            Text("0%").font(.caption2).minimumScaleFactor(0.5).lineLimit(1)
        }
    }
    .padding()
}
#endif
