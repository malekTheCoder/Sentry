import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the custom menu-bar battery glyph
/// (Sentry/MenuBar/BatteryGlyph.swift) and for the two places
/// `BarModuleRenderer` has to agree with it.
///
/// The glyph replaced the `battery.100` SF Symbol for two reasons, and both
/// are the kind of bug no compiler catches:
///
///  * the symbol was painted into a square icon slot, which squashed a 1.7:1
///    glyph horizontally, and
///  * it was static, so 5% and 100% drew identically.
///
/// So what is pinned here is the arithmetic behind both: the proportions, the
/// fill's continuous response to charge, the clamping at each end, and — the
/// one that would show up as visible corruption in the bar rather than as a
/// wrong-looking icon — that the width the layout pass reserves is the width
/// the draw pass consumes.
///
/// Nothing here asserts on pixels. Rendering is verified by eye; these tests
/// exist so the geometry cannot drift underneath that.
final class BatteryGlyphTests: XCTestCase {

    /// The slot size at the default 12pt bar font: `(barFontSize + 3).rounded()`.
    private let iconSize: CGFloat = 15

    private func metrics(charge: Double?, iconSize: CGFloat? = nil) -> BatteryGlyph.Metrics {
        BatteryGlyph.metrics(
            iconSize: iconSize ?? self.iconSize,
            x: 10,
            midY: 12,
            charge: charge
        )
    }

    // MARK: - Proportions (the "squished" half of the complaint)

    func testGlyphIsWiderThanTallInApplesRange() {
        // The whole point of the change: a battery-shaped battery. Apple's
        // indicator sits near 1.7:1; anything approaching 1:1 is the bug.
        for size in stride(from: CGFloat(11), through: 24, by: 1) {
            let m = metrics(charge: 0.5, iconSize: size)
            let ratio = m.totalWidth / m.body.height
            XCTAssertGreaterThan(ratio, 1.5, "glyph is nearly square at iconSize \(size)")
            XCTAssertLessThan(ratio, 2.0, "glyph is stretched at iconSize \(size)")
        }
    }

    func testGlyphIsOnlyModestlyWiderThanTheSquareItReplaced() {
        // The user asked for a correctly-proportioned battery, not a bigger
        // one: "it doesn't need to be much longer". A glyph that ate its
        // neighbours' space would be a different complaint.
        XCTAssertLessThanOrEqual(BatteryGlyph.width(iconSize: iconSize), iconSize * 1.25)
        XCTAssertGreaterThan(BatteryGlyph.width(iconSize: iconSize), iconSize * 0.9)
    }

    func testTerminalNubSitsOutsideTheBodyOnTheRight() {
        let m = metrics(charge: 1)
        XCTAssertGreaterThan(m.terminal.minX, m.body.maxX, "the nub must not overlap the body outline")
        XCTAssertLessThan(m.terminal.height, m.body.height)
        XCTAssertEqual(m.terminal.midY, m.body.midY, accuracy: 0.5)
    }

    // MARK: - Width agreement between the layout and draw passes

    func testReservedWidthMatchesDrawnWidth() {
        // A mismatch here does not look like a wrong icon — it looks like the
        // battery overlapping the module to its right, or a gap in the bar.
        for size in stride(from: CGFloat(11), through: 24, by: 1) {
            XCTAssertEqual(
                BatteryGlyph.width(iconSize: size),
                metrics(charge: 0.5, iconSize: size).totalWidth,
                accuracy: 0.001,
                "reserved and drawn widths diverge at iconSize \(size)"
            )
        }
    }

    func testWidthDoesNotMoveWithCharge() {
        // An advance that tracked the reading would shove every module to the
        // right of the battery back and forth as the pack drains.
        let widths = [nil, 0, 0.01, 0.23, 0.5, 1].map { metrics(charge: $0).totalWidth }
        XCTAssertEqual(Set(widths).count, 1, "glyph advance changed with charge: \(widths)")
    }

    // MARK: - Fill tracks charge continuously

    func testFillWidthIsProportionalToCharge() {
        let m = metrics(charge: 0.5)
        guard let fill = m.fill else { return XCTFail("50% must draw a fill") }
        XCTAssertEqual(fill.width, m.cavity.width / 2, accuracy: 0.001)
    }

    func testFullChargeFillsTheCavityExactly() {
        let m = metrics(charge: 1)
        guard let fill = m.fill else { return XCTFail("100% must draw a fill") }
        XCTAssertEqual(fill.width, m.cavity.width, accuracy: 0.001)
        XCTAssertTrue(m.cavity.contains(fill), "the fill escaped the cavity at 100%")
    }

    func testZeroChargeDrawsAnEmptyOutlineRatherThanASliver() {
        XCTAssertNil(metrics(charge: 0).fill)
    }

    func testTinyButNonZeroChargeStillDrawsSomething() {
        // 2% must not render as a flat-empty battery, but it also must not
        // render like 15% — the same trade `drawBar`'s 1.5pt nub makes.
        guard let small = metrics(charge: 0.02).fill,
              let bigger = metrics(charge: 0.15).fill else {
            return XCTFail("a non-zero charge must draw a fill")
        }
        XCTAssertGreaterThanOrEqual(small.width, 1)
        XCTAssertLessThan(small.width, bigger.width)
    }

    func testFillIsMonotonicInCharge() {
        // The bug being fixed was a glyph that ignored charge entirely; this
        // is the assertion that it never does so again over the whole range.
        var previous: CGFloat = 0
        for step in stride(from: 0.01, through: 1.0, by: 0.01) {
            let width = metrics(charge: step).fill?.width ?? 0
            XCTAssertGreaterThanOrEqual(width, previous, "fill shrank going from below \(step)")
            previous = width
        }
        XCTAssertGreaterThan(previous, 1)
    }

    func testDistinctChargesProduceDistinctFills() {
        // Continuous, not quantised into the five buckets SF Symbol's
        // battery.25/.50/.75 variants would have given.
        let widths = [0.38, 0.44, 0.51, 0.62].map { metrics(charge: $0).fill?.width ?? 0 }
        XCTAssertEqual(Set(widths).count, widths.count, "charges collapsed onto one fill: \(widths)")
    }

    // MARK: - Clamping and nonsense input

    func testChargeAboveOneIsClampedToAFullCavity() {
        guard let fill = metrics(charge: 5).fill else { return XCTFail("expected a fill") }
        XCTAssertEqual(fill.width, metrics(charge: 5).cavity.width, accuracy: 0.001)
    }

    func testNegativeChargeDrawsNoFillRatherThanAnInvertedOne() {
        XCTAssertNil(metrics(charge: -0.4).fill)
    }

    func testStateClampsOutOfRangeFractions() {
        XCTAssertEqual(BatteryGlyph.State(charge: 1.8, isCharging: false).charge, 1)
        XCTAssertEqual(BatteryGlyph.State(charge: -3, isCharging: false).charge, 0)
    }

    func testStateRejectsNonFiniteCharge() {
        // A NaN reaching the geometry would produce a NaN rect and CoreGraphics
        // would silently drop the fill — an empty battery at full charge.
        XCTAssertNil(BatteryGlyph.State(charge: .nan, isCharging: false).charge)
        XCTAssertNil(BatteryGlyph.State(charge: .infinity, isCharging: false).charge)
    }

    // MARK: - Unknown / no battery

    func testNoBatteryStatsIsUnknownRatherThanEmpty() {
        let state = BatteryGlyph.State(stats: nil)
        XCTAssertFalse(state.isKnown)
        XCTAssertNil(state.charge)
        XCTAssertFalse(state.showsBolt)
    }

    func testAGenuineZeroPercentIsDistinguishableFromUnknown() {
        // The distinction the whole optional exists for: a Mac mini has no
        // battery; a MacBook at 0% is about to shut down.
        let flat = BatteryGlyph.State(stats: BatteryStats(chargePercent: 0, isCharging: false, isPluggedIn: false))
        XCTAssertTrue(flat.isKnown)
        XCTAssertEqual(flat.charge, 0)
        XCTAssertFalse(BatteryGlyph.State(stats: nil).isKnown)
    }

    func testUnknownChargeDrawsNoFill() {
        XCTAssertNil(metrics(charge: nil).fill)
    }

    // MARK: - Charging

    func testChargingShowsTheBolt() {
        let state = BatteryGlyph.State(stats: BatteryStats(chargePercent: 40, isCharging: true, isPluggedIn: true))
        XCTAssertTrue(state.showsBolt)
        XCTAssertEqual(state.charge ?? 0, 0.4, accuracy: 0.0001)
    }

    func testPluggedInButNotChargingShowsNoBolt() {
        // macOS holds a battery at 80%, and pauses charging when the pack is
        // hot (`BatteryStats.notChargingReason`). A bolt in those states would
        // claim the battery is filling when it is not.
        let held = BatteryGlyph.State(
            stats: BatteryStats(chargePercent: 80, isCharging: false, isPluggedIn: true, notChargingReasonText: "held")
        )
        XCTAssertFalse(held.showsBolt)
    }

    func testOnBatteryShowsNoBolt() {
        XCTAssertFalse(
            BatteryGlyph.State(stats: BatteryStats(chargePercent: 55, isCharging: false, isPluggedIn: false)).showsBolt
        )
    }

    func testBoltFitsInsideTheBodyHorizontally() {
        // Including its dilated halo, which is what gets clipped out of the
        // fill — a halo spilling past the outline would eat the frame.
        let m = metrics(charge: 1)
        let halo = BatteryGlyph.boltPath(in: m.bolt, scale: BatteryGlyph.boltHaloScale).boundingBox
        XCTAssertGreaterThan(halo.minX, m.body.minX)
        XCTAssertLessThan(halo.maxX, m.body.maxX)
    }

    // MARK: - Pixel alignment (crispness at 12–18pt)

    func testBodyAndCavityAreOnWholePoints() {
        // A 1pt outline is the entire glyph at this size; a half-pixel offset
        // turns it into a grey smear.
        for size in stride(from: CGFloat(11), through: 24, by: 1) {
            let m = metrics(charge: 0.5, iconSize: size)
            for value in [m.body.minX, m.body.minY, m.body.width, m.body.height, m.cavity.minX, m.cavity.minY] {
                XCTAssertEqual(value, value.rounded(), accuracy: 0.0001, "non-integral geometry at iconSize \(size)")
            }
        }
    }

    func testOutlineStrokeSitsOnHalfPoints() {
        // Half-integer centres are pixel-aligned at 1x and at 2x; integer
        // centres are only aligned at 2x.
        let m = metrics(charge: 0.5)
        XCTAssertEqual(m.outline.minX - m.body.minX, m.lineWidth / 2, accuracy: 0.0001)
        XCTAssertEqual((m.outline.minX * 2).truncatingRemainder(dividingBy: 2), 1, accuracy: 0.0001)
    }

    func testCavityStaysInsideTheOutline() {
        let m = metrics(charge: 1)
        XCTAssertTrue(m.body.contains(m.cavity))
        XCTAssertGreaterThanOrEqual(m.cavity.minX - m.body.minX, m.lineWidth)
        XCTAssertGreaterThan(m.cavity.height, 0)
    }

    // MARK: - Renderer agreement

    private func renderer() -> BarModuleRenderer { BarModuleRenderer(theme: .oneDark, dark: true) }

    func testBatteryIconIsWiderThanASquareModuleIcon() {
        // The regression test for the original complaint, at the level the bar
        // actually measures: the battery no longer gets a square slot.
        let r = renderer()
        let charged = BatteryGlyph.State(charge: 0.5, isCharging: false)
        let battery = BarModule(metric: .batteryChargePercent, displayMode: .iconOnly)
        let cpu = BarModule(metric: .cpuTotalPercent, displayMode: .iconOnly)

        let batteryWidth = r.width(for: battery, value: 50, normalized: 0.5, history: [], battery: charged)
        let cpuWidth = r.width(for: cpu, value: 50, normalized: 0.5, history: [], battery: charged)
        XCTAssertGreaterThan(batteryWidth, cpuWidth)
    }

    func testUnknownBatteryReservesTheEmDashWidthNotTheGlyphWidth() {
        // With no reading the renderer draws `MetricFormatter.unavailable`
        // instead of an outline, so the reserved width has to follow it —
        // otherwise the em dash floats in a battery-sized hole.
        let r = renderer()
        let module = BarModule(metric: .batteryChargePercent, displayMode: .iconOnly)
        let known = r.width(for: module, value: 50, normalized: 0.5, history: [], battery: .init(charge: 0.5, isCharging: false))
        let unknown = r.width(for: module, value: nil, normalized: nil, history: [], battery: .unknown)
        XCTAssertNotEqual(known, unknown, accuracy: 0.001)
        XCTAssertEqual(unknown, r.measure(MetricFormatter.unavailable), accuracy: 0.001)
    }

    func testEveryDisplayModeStillProducesAPositiveWidthForTheBatteryModule() {
        // The glyph only replaces the icon, but `DisplayMode` has seven cases
        // and the battery module is legal in all of them; a mode that fell
        // through to a zero width would silently vanish from the bar.
        let r = renderer()
        for mode in DisplayMode.allCases {
            for state in [BatteryGlyph.State(charge: 0.42, isCharging: true), .unknown] {
                let module = BarModule(metric: .batteryChargePercent, displayMode: mode)
                let width = r.width(
                    for: module,
                    value: 42,
                    normalized: 0.42,
                    history: [10, 20, 30],
                    battery: state
                )
                XCTAssertGreaterThan(width, 0, "\(mode) with known=\(state.isKnown) reserved no width")
            }
        }
    }

    /// End-to-end through the real view, which is the only thing that proves
    /// the snapshot's battery actually reaches the glyph.
    func testStatusItemViewWidthRespondsToBatteryPresence() {
        let layout = MenuBarLayout(
            modules: [BarModule(metric: .batteryChargePercent, displayMode: .iconAndValue)],
            maxWidth: nil
        )
        var withBattery = SystemSnapshot(deviceID: "test-device")
        withBattery.battery = BatteryStats(chargePercent: 62, isCharging: true, isPluggedIn: true)

        let view = StatusItemView(layout: layout, theme: .oneDark)
        view.update(withBattery)
        let batteryWidth = view.intrinsicContentSize.width

        view.update(SystemSnapshot(deviceID: "test-device"))
        let noBatteryWidth = view.intrinsicContentSize.width

        XCTAssertGreaterThan(batteryWidth, 0)
        XCTAssertGreaterThan(noBatteryWidth, 0)
        XCTAssertNotEqual(batteryWidth, noBatteryWidth, accuracy: 0.001)
    }
}
