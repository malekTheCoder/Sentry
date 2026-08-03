import CoreGraphics
import SentryKit

/// The custom-drawn battery glyph for the menu bar: its geometry, its state,
/// and the paths `BarModuleRenderer` strokes and fills.
///
/// **Why this exists at all.** Every other module in the bar draws its SF
/// Symbol through `BarModuleRenderer.drawSymbol(for:color:in:)`, which paints
/// the glyph into `iconRect(at:in:)` — a *square*. That is fine for `cpuchip`,
/// `memorychip` and friends, which are roughly square natively. It is wrong
/// for `battery.100`, whose native aspect is about 1.7:1: squeezing it into a
/// square compresses it horizontally, which is exactly the "squished" glyph
/// users see next to Apple's own indicator.
///
/// **Why not just fix the rect and keep the symbol.** Two reasons. The rect
/// was only half the complaint — the SF Symbol is static, so the bar drew an
/// identical battery at 5% and at 100%. And the obvious fix for *that* (SF
/// Symbol's `battery.25` / `battery.50` / `battery.75` variants) quantises the
/// reading to five buckets. This app's entire premise is precise readings; a
/// glyph that shows "half" for everything between 38% and 62% is the same
/// class of lie as a fabricated sample. So the glyph is drawn from primitives
/// and the fill is continuous.
///
/// **Why a separate type rather than more methods on the renderer.** All of
/// the interesting behaviour here is arithmetic — where the fill edge lands
/// for a given charge, what clamps, what happens when the charge is unknown —
/// and none of it needs a graphics context. Keeping it in a pure value type
/// means the tests exercise the real geometry rather than a re-implementation
/// of it (`SentryTests/BatteryGlyphTests.swift`).
///
/// **Deliberately not done:** no cache. See
/// `BarModuleRenderer.drawBatteryGlyph(...)` for the reasoning; the short
/// version is that this glyph is a handful of `CGPath` fills with no `NSImage`
/// round-trip, so there is nothing expensive to memoise, and any cache key
/// faithful enough to preserve a continuous fill would have unbounded
/// cardinality.
struct BatteryGlyph {

    // MARK: - State

    /// What the glyph needs to know about the battery, distilled out of
    /// `BatteryStats` at the edge so the drawing code never reaches into the
    /// model (and so tests can construct impossible inputs directly).
    struct State: Equatable {
        /// Charge as a 0…1 fraction, or nil when there is no reading.
        ///
        /// Optional rather than defaulting to zero because a Mac mini has no
        /// battery at all and an IOKit read can fail transiently; drawing an
        /// empty battery in either case would assert "0%", which is a
        /// different — and alarming — claim from "no reading" (P5, and the
        /// same rule `BatteryStats.voltageMV` documents for its own nils).
        let charge: Double?
        /// True only when current is actually flowing *in*. Not the same as
        /// `isPluggedIn`; see `showsBolt`.
        let isCharging: Bool

        var isKnown: Bool { charge != nil }

        /// The bolt is drawn for `isCharging` alone, never for "on AC".
        ///
        /// Apple's indicator shows a bolt whenever the Mac is plugged in, but
        /// macOS routinely holds a battery at 80%, or stops charging when the
        /// pack is hot — `BatteryStats.notChargingReason` exists precisely
        /// because those states are common. A bolt in those states tells the
        /// user the battery is filling when it is not, which is the one thing
        /// this app does not do. Plugged-but-not-charging therefore draws as
        /// an ordinary battery: true, if less flashy.
        var showsBolt: Bool { isCharging }

        init(stats: BatteryStats?) {
            guard let stats else {
                self = .unknown
                return
            }
            self.init(charge: stats.chargePercent / 100, isCharging: stats.isCharging)
        }

        /// Fraction-based initialiser. Out-of-range and non-finite input is
        /// clamped/rejected here rather than at the drawing site so there is
        /// exactly one place a bad number can enter the glyph.
        init(charge: Double?, isCharging: Bool) {
            if let charge, charge.isFinite {
                self.charge = min(max(charge, 0), 1)
            } else {
                self.charge = nil
            }
            self.isCharging = isCharging
        }

        /// No battery hardware / no reading, and not charging.
        static let unknown = State(charge: nil, isCharging: false)
    }

    // MARK: - Metrics

    /// Every rectangle the renderer needs, resolved once.
    ///
    /// Pixel alignment is baked in here rather than left to the drawing code:
    /// at menu-bar size a 1pt outline is the whole glyph, and a 1pt stroke
    /// whose centre line sits on an integer point coordinate straddles two
    /// device pixels at 1x and renders as a grey smear. So `body`, `terminal`
    /// and `cavity` are integral rects and `outline` is `body` inset by half
    /// the line width — putting the stroke's centre on half-integers, which is
    /// pixel-aligned at 1x *and* at 2x.
    ///
    /// `fill` is the deliberate exception: its leading, top and bottom edges
    /// are snapped, but its trailing edge is left continuous. Snapping the
    /// edge that encodes the reading would quantise the charge to whole
    /// points — roughly 9% per step at menu-bar size — which is the same
    /// bucketing that ruled out the SF Symbol variants. A softly antialiased
    /// moving edge is the better trade.
    struct Metrics: Equatable {
        /// Integral outer bounds of the battery body (the stroke sits inside).
        let body: CGRect
        /// Path rect for the 1pt outline: `body` inset by `lineWidth / 2`.
        let outline: CGRect
        /// The nub on the right-hand end.
        let terminal: CGRect
        /// Interior region the fill may occupy at 100%.
        let cavity: CGRect
        /// The charge fill, or nil when the charge is unknown or zero.
        let fill: CGRect?
        /// Bounds the charging bolt is fitted into (centred on the body).
        let bolt: CGRect
        let lineWidth: CGFloat
        let cornerRadius: CGFloat
        let cavityRadius: CGFloat

        /// Total advance the layout pass must reserve, body through nub.
        var totalWidth: CGFloat { terminal.maxX - body.minX }
    }

    // MARK: - Proportions

    /// Glyph height as a fraction of the square icon slot the other modules
    /// use. Tuned so the battery reads as the same visual "weight" as its
    /// neighbours without dominating them.
    private static let heightRatio: CGFloat = 0.64

    /// Overall width (body + gap + nub) as a multiple of the height. Apple's
    /// indicator sits around 1.7:1; the user's own words were that it "doesn't
    /// need to be much longer", and at the default 12pt bar font this works
    /// out at 17pt against the old 15pt square — proportional, not bigger.
    private static let aspectRatio: CGFloat = 1.7

    /// Resolved integral dimensions for an icon slot. Single source of truth
    /// so `width(iconSize:)` and `metrics(...)` can never disagree — a layout
    /// pass that reserves a different width than the draw pass consumes is how
    /// a fixed glyph ends up overlapping its neighbour.
    private static func dimensions(iconSize: CGFloat) -> (
        height: CGFloat,
        bodyWidth: CGFloat,
        terminalWidth: CGFloat,
        terminalHeight: CGFloat,
        terminalGap: CGFloat,
        lineWidth: CGFloat
    ) {
        let height = max((iconSize * heightRatio).rounded(), 8)
        let terminalWidth = max((height * 0.12).rounded(), 1)
        let terminalGap = max((height * 0.10).rounded(), 1)
        // `max(_, height)` stops an absurdly small theme font from producing a
        // body narrower than it is tall, which would read as a square again.
        let bodyWidth = max((height * aspectRatio).rounded() - terminalWidth - terminalGap, height)
        let terminalHeight = max((height * 0.40).rounded(), 2)
        return (height, bodyWidth, terminalWidth, terminalHeight, terminalGap, 1)
    }

    /// Width the glyph occupies in an icon slot of `iconSize`.
    ///
    /// Independent of charge on purpose: a glyph whose advance moved with the
    /// reading would shove every module to its right one pixel back and forth
    /// as the battery drains.
    static func width(iconSize: CGFloat) -> CGFloat {
        let d = dimensions(iconSize: iconSize)
        return d.bodyWidth + d.terminalGap + d.terminalWidth
    }

    /// Lays the glyph out with its left edge at `x`, centred on `midY`.
    ///
    /// `charge` is passed rather than a whole `State` because the bolt is
    /// composited independently of the fill and only the fraction affects
    /// geometry.
    static func metrics(iconSize: CGFloat, x: CGFloat, midY: CGFloat, charge: Double?) -> Metrics {
        let d = dimensions(iconSize: iconSize)

        let originX = x.rounded()
        let originY = (midY - d.height / 2).rounded()
        let body = CGRect(x: originX, y: originY, width: d.bodyWidth, height: d.height)
        let outline = body.insetBy(dx: d.lineWidth / 2, dy: d.lineWidth / 2)

        let terminal = CGRect(
            x: body.maxX + d.terminalGap,
            y: (midY - d.terminalHeight / 2).rounded(),
            width: d.terminalWidth,
            height: d.terminalHeight
        )

        // The stroke eats `lineWidth` of the body; another point of clearance
        // keeps the fill from fusing with the outline into one dark slab, the
        // way Apple's does.
        let inset = d.lineWidth + 1
        let cavity = body.insetBy(dx: inset, dy: inset)

        var fill: CGRect?
        if let charge, charge > 0.005, cavity.width > 0, cavity.height > 0 {
            // A minimum sliver so a genuinely-nonzero charge is never drawn as
            // an empty battery, kept near-hairline for the same reason
            // `drawBar` keeps its nub at 1.5pt: clamping to something
            // comfortable made 2% and 15% identical.
            let width = max(cavity.width * CGFloat(min(max(charge, 0), 1)), 1)
            fill = CGRect(x: cavity.minX, y: cavity.minY, width: min(width, cavity.width), height: cavity.height)
        }

        // Taller than the cavity so it overlaps the outline's inner edge the
        // way Apple's bolt does — at 10pt a bolt confined to the cavity is an
        // unreadable smudge.
        let boltHeight = (d.height * 0.76).rounded()
        let boltWidth = (boltHeight * 0.62).rounded()
        let bolt = CGRect(
            x: (body.midX - boltWidth / 2).rounded(),
            y: (body.midY - boltHeight / 2).rounded(),
            width: boltWidth,
            height: boltHeight
        )

        return Metrics(
            body: body,
            outline: outline,
            terminal: terminal,
            cavity: cavity,
            fill: fill,
            bolt: bolt,
            lineWidth: d.lineWidth,
            cornerRadius: min((d.height * 0.22).rounded(), d.height / 2),
            cavityRadius: 1
        )
    }

    // MARK: - Bolt

    /// Lightning bolt as unit coordinates in a y-up box, traced as one closed
    /// polygon.
    ///
    /// Straight segments rather than the SF Symbol `bolt.fill` outline because
    /// the bolt has to be *dilated* (see `boltPath(in:scale:)`) to punch its
    /// own clearance out of the fill, and scaling a polygon about its centre
    /// is a faithful enough dilation at this size while scaling an arbitrary
    /// symbol path is not.
    private static let boltUnitPoints: [CGPoint] = [
        CGPoint(x: 0.60, y: 1.00),
        CGPoint(x: 0.08, y: 0.46),
        CGPoint(x: 0.40, y: 0.46),
        CGPoint(x: 0.34, y: 0.00),
        CGPoint(x: 0.90, y: 0.56),
        CGPoint(x: 0.56, y: 0.56),
    ]

    /// The bolt fitted to `rect`, optionally scaled about its own centre.
    ///
    /// `scale > 1` yields the "halo": the renderer clips it out of the charge
    /// fill so the bolt stays legible whether it lands on filled or empty
    /// battery. Without it a monochrome bar draws a same-coloured bolt on a
    /// same-coloured fill, i.e. nothing at all.
    static func boltPath(in rect: CGRect, scale: CGFloat = 1) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func map(_ unit: CGPoint) -> CGPoint {
            let point = CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
            guard scale != 1 else { return point }
            return CGPoint(
                x: center.x + (point.x - center.x) * scale,
                y: center.y + (point.y - center.y) * scale
            )
        }
        guard let first = boltUnitPoints.first else { return path }
        path.move(to: map(first))
        for unit in boltUnitPoints.dropFirst() { path.addLine(to: map(unit)) }
        path.closeSubpath()
        return path
    }

    /// How much bigger the punched-out halo is than the bolt itself. Enough to
    /// read as a gap at 10pt, small enough not to eat the fill around it.
    static let boltHaloScale: CGFloat = 1.45
}
