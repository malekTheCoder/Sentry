import XCTest
@testable import SentryKit

/// Coverage for `ThemeContrast.lifted(_:onto:toRatioAtLeast:)` and
/// `dimmed(_:toLuminanceAtMost:)` — the two repair operations the Watch app's
/// `WatchPalette` (`SentryWatch/Theme/WatchPalette.swift`) is built on.
///
/// **Why these are tested here rather than in the watch target.** The watch
/// app is an app target, not a framework, so nothing can import it — and the
/// guarantee that actually matters ("no theme can render invisible text on
/// the wrist") is arithmetic, not layout. Moving the arithmetic into
/// `SentryKit` is what made it reachable, and the preset sweep at the bottom
/// is the test that would have caught the bug this pass shipped and then
/// fixed: tokens were being contrast-checked against the black canvas while
/// actually being drawn on a lighter card, which passed the check and still
/// rendered grey-on-grey under the Paper preset.
final class ThemeContrastRepairTests: XCTestCase {

    private let black = ThemeColor.RGBA(red: 0, green: 0, blue: 0, alpha: 1)

    private func rgba(_ hex: String) -> ThemeColor.RGBA {
        guard let value = ThemeColor.components(fromHex: hex) else {
            XCTFail("fixture hex \(hex) must parse")
            return ThemeColor.RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return value
    }

    // MARK: - lifted

    func testAColourThatAlreadyPassesIsReturnedUnchanged() {
        // Paper's accent: a blue that is perfectly readable on black already.
        let accent = rgba("#0969DA")
        let lifted = ThemeContrast.lifted(accent, onto: black, toRatioAtLeast: 3.0)
        XCTAssertEqual(lifted.red, accent.red, accuracy: 0.0001)
        XCTAssertEqual(lifted.green, accent.green, accuracy: 0.0001)
        XCTAssertEqual(lifted.blue, accent.blue, accuracy: 0.0001)
    }

    func testNearBlackTextIsLiftedUntilItClearsTheRatio() {
        // Paper's textPrimary — about 1.1:1 on black, i.e. invisible.
        let text = rgba("#1F2328")
        XCTAssertLessThan(ThemeContrast.ratio(text, black), 2.0, "precondition: this fixture must start unreadable")

        let lifted = ThemeContrast.lifted(text, onto: black, toRatioAtLeast: 4.5)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(lifted, black), 4.5)
    }

    func testLiftingPreservesTheRelativeOrderOfTheChannels() {
        // A dark navy must come back a lighter navy, not a neutral: blue is
        // the dominant channel going in and must still be going out, which is
        // what "the theme stays recognisable" means concretely.
        let navy = rgba("#101A3C")
        let lifted = ThemeContrast.lifted(navy, onto: black, toRatioAtLeast: 4.5)
        XCTAssertGreaterThan(lifted.blue, lifted.green)
        XCTAssertGreaterThan(lifted.green, lifted.red)
    }

    func testLiftingIsMeasuredAgainstTheGivenBackdropNotAlwaysBlack() {
        // The bug this whole helper's `onto:` parameter exists for: a token
        // lifted just far enough for black is *not* far enough for a card
        // several shades up from black.
        let card = rgba("#3A3A3A")
        let text = rgba("#1F2328")

        let forBlack = ThemeContrast.lifted(text, onto: black, toRatioAtLeast: 4.5)
        XCTAssertLessThan(
            ThemeContrast.ratio(forBlack, card), 4.5,
            "a lift computed against black must not be assumed safe on a lighter card"
        )

        let forCard = ThemeContrast.lifted(text, onto: card, toRatioAtLeast: 4.5)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(forCard, card), 4.5)
    }

    func testATranslucentTokenIsFlattenedOntoTheBackdropBeforeBeingJudged() {
        let ghost = ThemeColor.RGBA(red: 1, green: 1, blue: 1, alpha: 0.04)
        let lifted = ThemeContrast.lifted(ghost, onto: black, toRatioAtLeast: 4.5)
        XCTAssertEqual(lifted.alpha, 1, "the result must be opaque, not carry the original's alpha")
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(lifted, black), 4.5)
    }

    // MARK: - dimmed

    func testAWhiteSurfaceIsPulledDownToTheCeiling() {
        let white = rgba("#FFFFFF")
        let dimmed = ThemeContrast.dimmed(white, toLuminanceAtMost: 0.055)
        XCTAssertLessThanOrEqual(ThemeContrast.relativeLuminance(dimmed), 0.055 + 0.0005)
    }

    func testAnAlreadyDarkSurfaceIsReturnedUnchanged() {
        // Notion's dark surface, well under the ceiling.
        let surface = rgba("#202020")
        let dimmed = ThemeContrast.dimmed(surface, toLuminanceAtMost: 0.055)
        XCTAssertEqual(dimmed.red, surface.red, accuracy: 0.0001)
        XCTAssertEqual(dimmed.blue, surface.blue, accuracy: 0.0001)
    }

    func testDimmingPreservesHueByScalingAllChannelsEqually() {
        // GitHub's cool grey must stay cool: the blue channel leads going in
        // and must still lead going out.
        let cool = rgba("#F6F8FA")
        let dimmed = ThemeContrast.dimmed(cool, toLuminanceAtMost: 0.055)
        XCTAssertGreaterThan(dimmed.blue, dimmed.red, "a cool grey must not come back neutral")
        XCTAssertEqual(dimmed.blue / dimmed.red, cool.blue / cool.red, accuracy: 0.01)
    }

    // MARK: - The guarantee, across every built-in preset

    /// The test the Watch redesign actually rests on: for **every** built-in
    /// theme — light presets included — the tokens the watch renders come
    /// back readable against the card they are drawn on.
    ///
    /// Mirrors `WatchPalette`'s own pipeline exactly: dim the surface to the
    /// card ceiling, then lift each token onto *that* rather than onto black.
    func testEveryBuiltInPresetProducesReadableWatchTokens() {
        let surfaceCeiling = 0.055
        let textRatio = 4.5
        let graphicRatio = 3.0

        for theme in Theme.builtInPresets {
            guard let rawSurface = theme.surface.rgba(for: .dark) else {
                XCTFail("\(theme.id): surface must parse")
                continue
            }
            let flatSurface = rawSurface.alpha < 1
                ? ThemeContrast.flatten(rawSurface, onto: black)
                : rawSurface
            let card = ThemeContrast.dimmed(flatSurface, toLuminanceAtMost: surfaceCeiling)

            XCTAssertLessThanOrEqual(
                ThemeContrast.relativeLuminance(card), surfaceCeiling + 0.0005,
                "\(theme.id): card fill must be dark enough to sit on an OLED watch canvas"
            )

            let textTokens: [(String, ThemeColor)] = [
                ("textPrimary", theme.textPrimary),
                ("textSecondary", theme.textSecondary),
            ]
            for (name, token) in textTokens {
                guard let value = token.rgba(for: .dark) else {
                    XCTFail("\(theme.id): \(name) must parse")
                    continue
                }
                let fixed = ThemeContrast.lifted(value, onto: card, toRatioAtLeast: textRatio)
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.ratio(fixed, card), textRatio - 0.01,
                    "\(theme.id): \(name) must be readable on the watch card"
                )
            }

            let graphicTokens: [(String, ThemeColor)] = [
                ("accent", theme.accent),
                ("success", theme.success),
                ("warning", theme.warning),
                ("danger", theme.danger),
                ("textTertiary", theme.textTertiary),
            ]
            for (name, token) in graphicTokens {
                guard let value = token.rgba(for: .dark) else {
                    XCTFail("\(theme.id): \(name) must parse")
                    continue
                }
                let fixed = ThemeContrast.lifted(value, onto: card, toRatioAtLeast: graphicRatio)
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.ratio(fixed, card), graphicRatio - 0.01,
                    "\(theme.id): \(name) must be visible on the watch card"
                )
            }
        }
    }

    /// The escalation vocabulary has to survive the repair. If a preset's
    /// warning and danger both got lifted all the way to near-white, a
    /// critical dial and an elevated one would render identically — which is
    /// the failure `MetricSeverity` exists to prevent.
    func testWarningAndDangerStayDistinguishableAfterRepairInEveryPreset() {
        for theme in Theme.builtInPresets {
            guard let surface = theme.surface.rgba(for: .dark),
                  let warning = theme.warning.rgba(for: .dark),
                  let danger = theme.danger.rgba(for: .dark) else {
                XCTFail("\(theme.id): tokens must parse")
                continue
            }
            let card = ThemeContrast.dimmed(surface, toLuminanceAtMost: 0.055)
            let fixedWarning = ThemeContrast.lifted(warning, onto: card, toRatioAtLeast: 3.0)
            let fixedDanger = ThemeContrast.lifted(danger, onto: card, toRatioAtLeast: 3.0)

            let distance = abs(fixedWarning.red - fixedDanger.red)
                + abs(fixedWarning.green - fixedDanger.green)
                + abs(fixedWarning.blue - fixedDanger.blue)
            XCTAssertGreaterThan(
                distance, 0.08,
                "\(theme.id): warning and danger must not collapse into the same colour after repair"
            )
        }
    }
}
