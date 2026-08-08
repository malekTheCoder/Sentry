import SwiftUI
import Charts

/// The interaction half of chart scrubbing on iOS: an invisible hit area over
/// a `Chart`'s plot rectangle that reports the x-axis `Date` under the finger,
/// plus a readout that follows it.
///
/// **Why the minimum drag distance is 10 and not 0.** Every chart in this app
/// lives inside the History tab's `ScrollView`. A `DragGesture(minimumDistance: 0)`
/// claims the touch the instant a finger lands, so the scroll view never sees
/// the pan that follows and the page stops scrolling wherever a chart happens
/// to be — the tab's primary interaction, broken by its secondary one. With a
/// non-zero minimum the two gestures race for the first few points of
/// movement: a mostly-vertical drag is claimed by the scroll view (which
/// cancels this one), while a horizontal drag along the plot reaches here.
/// 10pt is the same order as UIKit's own scroll slop, which is what makes the
/// hand-off feel like the system's rather than like a fight.
///
/// **Why scrubbing produces no haptic, decided rather than forgotten.**
/// `SentryHaptic`'s header (`SentryMobile/Theme/Haptics.swift`) rules out
/// anything continuous and then leaves this one case open: "chart scrubbing
/// is the one place a *very* light tick is arguably right, and it is handled
/// separately at that call site with its own throttling." This is that call
/// site, and the answer is no — because the only throttle that would be
/// principled here does not actually thin anything out.
///
/// The honest unit for a scrub tick is one per *data point crossed*, not one
/// per touch-move event; a tick per event is a function of how fast a finger
/// moves and means nothing. But count the points. `BatteryHealthTrendChart`
/// draws up to ninety daily records across a plot roughly 330pt wide — a
/// point every 3.7pt. `MobileActivityChart` draws a sixty-sample ring in
/// about the same width — a point every 5.5pt. A finger crossing a plot in
/// half a second would cross sixty to ninety points, so "one tick per point"
/// *is* a continuous vibration, arriving at 120–180 Hz. That is precisely
/// the "unpleasant within about two seconds" outcome the header rules out,
/// reached by way of the throttle that was supposed to prevent it. Coarser
/// throttles — every nth point, or a minimum interval — were rejected for
/// the reason this codebase rejects most "make it fit" fixes: the tick would
/// then correspond to nothing the reader can see, and a haptic that
/// corresponds to nothing is noise.
///
/// Firing only at the edges of a gap (entering or leaving a stretch with no
/// records) was the close runner-up: those are genuinely rare and discrete.
/// It was rejected because a gap edge is not something the user *did* — it
/// is a property of the data their finger happened to slide over — and
/// because it would need a tenth meaning the vocabulary does not have. The
/// readout already says "no reading for this day" in words, at the finger,
/// which is the right channel for it.
///
/// **Why there is a macOS copy of this file.** See
/// `Sentry/Dashboard/ChartScrubOverlay.swift` — the gesture tuning above and
/// the Dynamic Type handling below are exactly the parts that differ per
/// platform. The arithmetic both platforms share lives once, in
/// `SentryKit/History/ChartScrubbing.swift`.
struct ChartScrubOverlay<Readout: View>: View {
    let proxy: ChartProxy

    /// The raw, un-snapped date under the finger. Snapping (and deciding
    /// whether there is any data there at all) is the caller's job, via
    /// `ChartScrubbing.resolve(at:timestamps:cadence:)`.
    @Binding var scrubDate: Date?

    /// Where to pin the readout horizontally, in x-axis units — normally the
    /// snapped sample's timestamp. `nil` hides the readout.
    let anchor: Date?

    @ViewBuilder let readout: () -> Readout

    @State private var readoutWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if let plotAnchor = proxy.plotFrame {
                let plot = geometry[plotAnchor]
                ZStack(alignment: .topLeading) {
                    hitArea(plot: plot)
                    if let anchor, let x = proxy.position(forX: anchor) {
                        readoutLabel(centerX: x + plot.minX, plot: plot)
                    }
                }
            }
        }
    }

    private func hitArea(plot: CGRect) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: plot.width, height: plot.height)
            .offset(x: plot.minX, y: plot.minY)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        scrubDate = proxy.value(atX: value.location.x - plot.minX, as: Date.self)
                    }
                    // Clearing on end rather than latching the last position:
                    // a readout left standing after the finger lifts looks
                    // like a selection the user has to dismiss, and there is
                    // nothing here to dismiss it with.
                    .onEnded { _ in scrubDate = nil }
            )
    }

    private func readoutLabel(centerX: CGFloat, plot: CGRect) -> some View {
        let leading = min(
            max(centerX - readoutWidth / 2, plot.minX),
            max(plot.maxX - readoutWidth, plot.minX)
        )
        return readout()
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ScrubReadoutWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(ScrubReadoutWidthKey.self) { readoutWidth = $0 }
            .allowsHitTesting(false)
            .offset(x: leading, y: plot.minY + 4)
    }
}

private struct ScrubReadoutWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Readout chrome

extension View {
    /// The plate every scrub readout on iOS wears: theme `surfaceElevated`
    /// with a hairline `separator` border — no new colours, the same tokens
    /// the cards around it use.
    ///
    /// **The Dynamic Type bound.** The readout floats *over* the plot, and
    /// unlike prose it cannot reflow into more vertical space without covering
    /// the very data it is describing: at the largest accessibility sizes an
    /// unbounded "Mar 14 · 92.4%" grew tall enough to hide the line under it.
    /// Capped at `xxLarge` for exactly the reason
    /// `BatteryHealthTrendChart`'s axis labels are — see the comment there.
    /// Everything outside the plot (the card's title, its summary, the empty
    /// state) still scales to the full range, because those reflow.
    func chartScrubPlate(_ palette: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(palette.cornerRadius - 2, 3), style: .continuous)
        return self
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(shape.fill(palette.surfaceElevated))
            .overlay(shape.stroke(palette.separator, lineWidth: 1))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            // Transient touch affordance, not content: VoiceOver reaches the
            // same numbers through the chart's `AXChartDescriptor`, and a
            // label that appears and vanishes with a finger would be noise in
            // a navigation model that has no finger.
            .accessibilityHidden(true)
    }
}
