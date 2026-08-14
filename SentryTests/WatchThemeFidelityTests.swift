import XCTest
@testable import SentryKit

/// Locks in the contract the Watch app's `WatchPalette`
/// (`SentryWatch/Theme/WatchPalette.swift`) rests on: **the watch renders the
/// theme exactly, not an adjusted version of it.**
///
/// **Why this test exists and what it is defending against.** The watch
/// palette previously ran every token through a WCAG contrast floor before
/// drawing it. That was load-bearing while the watch canvas was hardcoded
/// black — a preset authored for a warm paper page cannot survive on a
/// background it was never designed for — and became a distortion the moment
/// the canvas became the theme's own `background`. The failure mode is quiet
/// and specific: nothing crashes, nothing looks broken, the wrist just draws
/// a heavier, higher-contrast version of a palette the Mac and phone draw
/// softly, and the user reports that it "doesn't match."
///
/// `WatchPalette` itself lives in an app target and cannot be imported here,
/// so these tests assert the two things about `SentryKit` that the palette's
/// correctness actually depends on: that resolving a token for an appearance
/// returns the authored value untouched, and that the specific ratios which
/// *would* have been "repaired" are real, so the removal was a behaviour
/// change rather than a no-op cleanup.
final class WatchThemeFidelityTests: XCTestCase {

    /// The theme the product's own screenshots are shot in — warm paper
    /// neutrals, terracotta accent, muted dusty metric hues.
    private let ivory = Theme.ivory

    private func hex(_ token: ThemeColor, _ appearance: ThemeAppearance = .light) throws -> String {
        let rgba = try XCTUnwrap(token.rgba(for: appearance))
        func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgba.red), byte(rgba.green), byte(rgba.blue))
    }

    // MARK: - The authored values, resolved verbatim

    /// Every token the watch draws, asserted against the literal hex in
    /// `Theme.ivory`. If someone reintroduces a "safe" adjustment in the
    /// resolve path, these fail with the substituted value rather than
    /// shipping a wrong-looking watch.
    func testIvoryResolvesToItsAuthoredHexValues() throws {
        XCTAssertEqual(try hex(ivory.background), "#FAF9F5")
        XCTAssertEqual(try hex(ivory.surface), "#F0EEE6")
        XCTAssertEqual(try hex(ivory.surfaceElevated), "#E6E3D8")
        XCTAssertEqual(try hex(ivory.textPrimary), "#3D3D3A")
        XCTAssertEqual(try hex(ivory.textSecondary), "#73726C")
        XCTAssertEqual(try hex(ivory.textTertiary), "#A3A29A")
        XCTAssertEqual(try hex(ivory.accent), "#C96442")
        XCTAssertEqual(try hex(ivory.success), "#6A8F5F")
        XCTAssertEqual(try hex(ivory.warning), "#A8742F")
        XCTAssertEqual(try hex(ivory.danger), "#BF4D43")
        XCTAssertEqual(try hex(ivory.separator), "#E4E2D8")
    }

    func testIvoryMetricColoursResolveToTheirAuthoredHexValues() throws {
        XCTAssertEqual(try hex(XCTUnwrap(ivory.metricColor(for: .cpuTotalPercent))), "#5F7DA8")
        XCTAssertEqual(try hex(XCTUnwrap(ivory.metricColor(for: .memoryUsedBytes))), "#8A6FA8")
        XCTAssertEqual(try hex(XCTUnwrap(ivory.metricColor(for: .diskReadBytesPerSec))), "#8A8778")
        XCTAssertEqual(try hex(XCTUnwrap(ivory.metricColor(for: .gpuUtilizationPercent))), "#A86F8E")
    }

    /// An appearance-fixed token stores the same string in both halves
    /// (`ThemeColor(hex:)`), so the watch asking for `.light` and the watch
    /// asking for `.dark` must agree. Every shipped preset now carries a
    /// real light/dark pair, so the fixture is a constructed fixed token —
    /// the case still exists in the wild via custom themes imported from
    /// builds that predate the pairing.
    func testAFixedTokenResolvesIdenticallyInBothAppearances() throws {
        for token in [ThemeColor(hex: "#FAF9F5"), ThemeColor(hex: "#C96442", opacity: 0.8)] {
            XCTAssertEqual(try hex(token, .light), try hex(token, .dark))
        }
    }

    // MARK: - The repair that was removed was not a no-op

    /// The two tokens a WCAG floor would have changed, with the ratios that
    /// prove it. If these ever start passing 4.5/3.0 on their own, the
    /// argument in `WatchPalette.color(_:fallback:)` needs revisiting — but
    /// until then this is the evidence that removing the repair changed what
    /// the user sees, which is the whole point.
    func testIvorysSofterTextTiersWouldHaveBeenAlteredByAWCAGFloor() throws {
        let surface = try XCTUnwrap(ivory.surface.rgba(for: .light))
        let secondary = try XCTUnwrap(ivory.textSecondary.rgba(for: .light))
        let tertiary = try XCTUnwrap(ivory.textTertiary.rgba(for: .light))

        XCTAssertLessThan(
            ThemeContrast.ratio(secondary, surface), 4.5,
            "textSecondary sits under AA on its own surface — a text floor would have darkened it"
        )
        XCTAssertLessThan(
            ThemeContrast.ratio(tertiary, surface), 3.0,
            "textTertiary sits under the graphical floor — a repair would have darkened it too"
        )

        // And confirm the repair really would have moved them, rather than
        // returning them untouched for some other reason.
        let repaired = ThemeContrast.legible(tertiary, onto: surface, toRatioAtLeast: 3.0)
        XCTAssertNotEqual(repaired.red, tertiary.red, accuracy: 0.0001)
    }

    /// The counterpart: the tokens that carry meaning are comfortably legible
    /// as authored, so rendering them verbatim is not shipping an unreadable
    /// watch. This is the reassurance that "exact" and "readable" are not in
    /// conflict for this theme.
    func testIvorysPrimaryTextAndSemanticTokensAreLegibleAsAuthored() throws {
        let surface = try XCTUnwrap(ivory.surface.rgba(for: .light))

        let primary = try XCTUnwrap(ivory.textPrimary.rgba(for: .light))
        XCTAssertGreaterThan(ThemeContrast.ratio(primary, surface), 4.5)

        for (name, token) in [
            ("accent", ivory.accent), ("success", ivory.success),
            ("warning", ivory.warning), ("danger", ivory.danger),
        ] {
            let rgba = try XCTUnwrap(token.rgba(for: .light))
            XCTAssertGreaterThan(
                ThemeContrast.ratio(rgba, surface), 3.0,
                "\(name) must clear the graphical floor as authored"
            )
        }
    }

    // MARK: - The one override the palette still makes

    /// `WatchPalette.metricColor` falls back to the accent when a preset has
    /// aliased a metric onto its own warning or danger token, because three
    /// side-by-side dials with one drawn in the alarm colour says a healthy
    /// Mac is sick. Asserted here as the property the palette tests for,
    /// using the same 0.08 summed-channel distance.
    private func collides(_ candidate: ThemeColor.RGBA, with theme: Theme, _ appearance: ThemeAppearance) -> Bool {
        [theme.warning, theme.danger]
            .compactMap { $0.rgba(for: appearance) }
            .contains { severity in
                abs(severity.red - candidate.red)
                    + abs(severity.green - candidate.green)
                    + abs(severity.blue - candidate.blue) < 0.08
            }
    }

    func testIvoryKeepsAllThreeWatchMetricColoursBecauseNoneAliasSeverity() throws {
        for metric in [MetricID.cpuTotalPercent, .memoryUsedBytes, .diskReadBytesPerSec] {
            let rgba = try XCTUnwrap(XCTUnwrap(ivory.metricColor(for: metric)).rgba(for: .light))
            XCTAssertFalse(
                collides(rgba, with: ivory, .light),
                "\(metric.rawValue) must keep Ivory's own hue on the watch"
            )
        }
    }

    /// System is a case the override exists for: `nocturneMetricColors`
    /// sends `memory.used_bytes` straight to `warning`, so the watch must
    /// *not* draw a normal-pressure memory dial in the alarm colour.
    func testSystemsMemoryMetricIsCorrectlyDetectedAsAliasingWarning() throws {
        let system = Theme.system
        let memory = try XCTUnwrap(XCTUnwrap(system.metricColor(for: .memoryUsedBytes)).rgba(for: .dark))
        XCTAssertTrue(
            collides(memory, with: system, .dark),
            "System aliases memory onto warning — the watch has to override it"
        )

        // CPU does not alias anything, and must survive the same check.
        let cpu = try XCTUnwrap(XCTUnwrap(system.metricColor(for: .cpuTotalPercent)).rgba(for: .dark))
        XCTAssertFalse(collides(cpu, with: system, .dark), "the override must be narrow, not blanket")
    }
}
