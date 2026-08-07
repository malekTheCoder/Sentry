import SwiftUI
import Charts

/// The interaction half of chart scrubbing on macOS: an invisible hit area
/// laid over a `Chart`'s plot rectangle that reports the x-axis `Date` under
/// the pointer, plus a floating readout pinned near that position.
///
/// **Why hover *and* drag.** On the Mac, hovering is the idiom — iStat Menus
/// and Stats both read out values under the pointer with no click, and
/// requiring a click to read a chart would feel broken. `onContinuousHover`
/// covers that. The `DragGesture(minimumDistance: 0)` is not redundant with
/// it: a trackpad user who presses and drags along the plot gets no hover
/// events for the duration of the drag, so without it the readout would freeze
/// mid-gesture. Both feed the same binding, so whichever fires last wins and
/// they can't disagree.
///
/// **Why this is not in `SentryKit`.** Its iOS counterpart
/// (`SentryMobile/History/ChartScrubOverlay.swift`) differs in the two places
/// that matter — the gesture's minimum distance (see that file for why a phone
/// cannot use 0) and the typography (Dynamic Type). The arithmetic both share
/// *is* factored out, into `SentryKit/History/ChartScrubbing.swift`; what is
/// duplicated here is only the platform-specific rendering, the same split
/// `ThemeColor+SwiftUI.swift` already exists twice for.
struct ChartScrubOverlay<Readout: View>: View {
    let proxy: ChartProxy

    /// The raw, un-snapped date under the pointer — raw on purpose, because
    /// "the pointer is 4 hours into an overnight gap" is information the
    /// caller needs and a pre-snapped date would have destroyed. Callers snap
    /// via `ChartScrubbing.resolve(at:timestamps:cadence:)`.
    @Binding var scrubDate: Date?

    /// Where to pin the readout horizontally, in x-axis units. Normally the
    /// *snapped* sample's timestamp, so the label sits over the dot rather
    /// than over the pointer — the two are visibly different on a sparse
    /// chart, and a label that doesn't line up with the marked point reads as
    /// a rendering bug. `nil` hides the readout.
    let anchor: Date?

    @ViewBuilder let readout: () -> Readout

    /// Measured width of the readout, so it can be centred on the anchor and
    /// clamped inside the plot. Kept in state (rather than re-measured inline)
    /// because it only changes when the *text* changes — "1.2 GB" is wider
    /// than "4%" — not on every pointer move.
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
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    scrubDate = proxy.value(atX: location.x, as: Date.self)
                case .ended:
                    scrubDate = nil
                }
            }
            .gesture(
                // `minimumDistance: 0` so a press without movement already
                // scrubs. There is no scroll view competing for the gesture
                // on this platform (the Dashboard scrolls with the wheel, not
                // by dragging content), which is exactly why the phone build
                // cannot copy this number.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubDate = proxy.value(atX: value.location.x - plot.minX, as: Date.self)
                    }
                    .onEnded { _ in scrubDate = nil }
            )
    }

    /// The floating label, centred on the anchor and slid back inside the plot
    /// when it would overhang. Clamping rather than letting it centre
    /// unconditionally: at either edge a centred label would hang off the card
    /// and get clipped by the surrounding `ScrollView`, and a readout you can
    /// only half-read at the ends of the chart is worse than one that nudges.
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
            // Never intercept the pointer: the hit area underneath must keep
            // receiving hover events even when the label is directly under the
            // cursor, or the readout would flicker off the moment it appeared
            // beneath the mouse.
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

/// A chart's current scrub readout, published upward for a host that has more
/// room for it than the plot does.
///
/// **Why a preference and not a binding or a callback.** The compact grid
/// sparklines (`DashboardChart` with `compact: true`) are scrubbable but have
/// nowhere inside a 36pt plot to put a readout plate — the label belongs on the
/// card, in the line the subtitle already occupies. That means the string has to
/// travel *up* the view tree. A `@Binding` would make every call site invent and
/// own a piece of state it otherwise has no use for (including the several that
/// don't want the readout at all), and a plain callback fired from inside `body`
/// is a state mutation during view update — the classic SwiftUI purple-warning
/// shape. A preference is the mechanism this exact problem has: it flows child →
/// parent, costs nothing when nobody reads it, and `ChartScrubOverlay` already
/// uses one three lines above for its own measured width.
///
/// `nil` means "not scrubbing" — the host falls back to whatever it normally
/// shows in that slot.
struct ChartScrubReadoutKey: PreferenceKey {
    static let defaultValue: String? = nil
    /// Last non-nil wins. A card hosts exactly one chart today, so this never
    /// actually arbitrates between two; the rule exists so that if one ever
    /// hosts two, a chart being hovered beats a chart that isn't, rather than
    /// whichever happens to be later in the tree blanking the other's readout.
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

// MARK: - Readout chrome

/// The one visual treatment every scrub readout in the Mac app wears: a small
/// rounded plate in the theme's elevated surface with a hairline border.
///
/// No new colours — `surfaceElevated` / `separator` / `textPrimary` are the
/// same tokens `dashboardCard` uses, so a user-authored theme styles the
/// readout for free and a readout can never clash with the card under it.
struct ChartScrubPlate: ViewModifier {
    let palette: ThemePalette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(palette.cornerRadius - 2, 3), style: .continuous)
        return content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(shape.fill(palette.surfaceElevated))
            .overlay(shape.stroke(palette.separator, lineWidth: 1))
            // The readout is a transient pointer affordance, not content:
            // VoiceOver reaches the same numbers through the chart's
            // `AXChartDescriptor` (see `DashboardChart.makeChartDescriptor`),
            // and announcing a label that appears and vanishes with the mouse
            // would be noise in a cursor-free navigation model.
            .accessibilityHidden(true)
    }
}

extension View {
    func chartScrubPlate(_ palette: ThemePalette) -> some View {
        modifier(ChartScrubPlate(palette: palette))
    }
}
