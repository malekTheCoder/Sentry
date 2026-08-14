import XCTest
@testable import SentryKit

/// The sweep that stops the invisible-switch bug coming back.
///
/// **What went wrong.** Every `Toggle` in the product rendered with AppKit's
/// stock switch. One call site out of forty-two applied `.tint(_:)`, which
/// only recolours the *on* track, so the off state was drawn in a system grey
/// picked against AppKit's window colours and never against this app's
/// palettes. On Ivory — grouped rows on `#F0EEE6`, dropdown cards on
/// `#E6E3D8` — that grey is within a few percent of the surface behind it and
/// the control is invisible. The Keep Awake row in the dropdown was the
/// screenshot; the Alerts pane's rule list was the same failure at scale.
///
/// **Why the test is the deliverable and not the fix.** Picking better colours
/// once is a fix with a shelf life of exactly one new preset. This file sweeps
/// `Theme.builtInPresets` — the array itself, never a hardcoded list — across
/// both appearances and all three surfaces a switch is genuinely drawn on, so
/// the next preset is graded the day it is added by someone who has never
/// read this comment. That is the whole point: the failure mode is silent,
/// nothing crashes, and a human eyeballing every theme will not reliably catch
/// a 2.6:1 border.
///
/// **The floors, and where they are argued.** 3:1 for enabled components
/// (WCAG 2.1 SC 1.4.11), 1.8:1 for disabled ones, 2:1 between the two states.
/// Each is a `public static let` on `ThemeControlColors` with its own
/// justification, including the one deviation from the spec — the disabled
/// floor, which WCAG does not require at all and which exists here because
/// "exempt" is how the Alerts pane's disabled rules would have become blank
/// space.
final class ThemedControlContrastTests: XCTestCase {

    // MARK: - Helpers

    /// Every combination a themed switch is actually rendered in.
    /// `Theme.builtInPresets` rather than a literal list — see the class doc.
    private func sweep(
        _ body: (Theme, ThemeAppearance, ThemeColorToken, Bool) throws -> Void
    ) rethrows {
        for theme in Theme.builtInPresets {
            for appearance in ThemeAppearance.allCases {
                for surface in ThemeControlColors.hostSurfaces {
                    for isEnabled in [true, false] {
                        try body(theme, appearance, surface, isEnabled)
                    }
                }
            }
        }
    }

    private func label(
        _ theme: Theme,
        _ appearance: ThemeAppearance,
        _ surface: ThemeColorToken,
        _ isEnabled: Bool
    ) -> String {
        "\(theme.name) / \(appearance.rawValue) / on \(surface.rawValue) / "
            + (isEnabled ? "enabled" : "disabled")
    }

    private func assertRatio(
        _ foreground: ThemeColor.RGBA,
        _ background: ThemeColor.RGBA,
        atLeast minimum: Double,
        _ what: String,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ratio = ThemeContrast.ratio(foreground, background)
        XCTAssertGreaterThanOrEqual(
            ratio, minimum,
            "\(context): \(what) is \(ThemeContrast.format(ratio)), below the \(minimum):1 floor.",
            file: file, line: line
        )
    }

    // MARK: - The sweep

    /// Nothing in the built-in set is so malformed that a switch cannot be
    /// derived for it. `init?` returns `nil` only on an unparseable backdrop
    /// token, which for a built-in preset would be a typo in `Theme.swift`.
    func testEveryPresetResolvesSwitchColours() {
        sweep { theme, appearance, surface, isEnabled in
            XCTAssertNotNil(
                ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: isEnabled),
                "\(label(theme, appearance, surface, isEnabled)): could not derive switch colours."
            )
        }
    }

    /// **The bug, asserted.** The off state must read as a control against the
    /// surface it is drawn on. Graded on the *border*, because that is what
    /// carries the affordance — the fill is deliberately a quiet recess and is
    /// checked separately below.
    func testOffSwitchBorderClearsItsFloorOnEverySurface() throws {
        try sweep { theme, appearance, surface, isEnabled in
            let colors = try XCTUnwrap(
                ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: isEnabled)
            )
            assertRatio(
                colors.offBorder, colors.backdrop,
                atLeast: isEnabled
                    ? ThemeControlColors.componentMinimumRatio
                    : ThemeControlColors.disabledMinimumRatio,
                "off-track border vs surface",
                label(theme, appearance, surface, isEnabled)
            )
        }
    }

    /// The recess has to be a recess. A fill identical to the backdrop would
    /// satisfy the border check above while making the switch look like a
    /// floating outline rather than a trough.
    func testOffTrackFillIsDistinguishableFromItsSurface() throws {
        try sweep { theme, appearance, surface, isEnabled in
            let colors = try XCTUnwrap(
                ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: isEnabled)
            )
            assertRatio(
                colors.offTrack, colors.backdrop,
                atLeast: 1.10,
                "off-track fill vs surface",
                label(theme, appearance, surface, isEnabled)
            )
        }
    }

    /// The on state is a filled control, so its *fill* is what has to clear
    /// the floor — and its border too, so the outline never disappears on one
    /// state and returns on the other.
    func testOnSwitchTrackAndBorderClearTheirFloor() throws {
        try sweep { theme, appearance, surface, isEnabled in
            let colors = try XCTUnwrap(
                ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: isEnabled)
            )
            let floor = isEnabled
                ? ThemeControlColors.componentMinimumRatio
                : ThemeControlColors.disabledMinimumRatio
            let context = label(theme, appearance, surface, isEnabled)
            assertRatio(colors.onTrack, colors.backdrop, atLeast: floor, "on-track fill vs surface", context)
            assertRatio(colors.onBorder, colors.backdrop, atLeast: floor, "on-track border vs surface", context)
        }
    }

    /// The knob is the channel that carries state without hue, so it has to be
    /// visible in *both* states — graded against whichever track it is sitting
    /// on, which is what it is literally drawn against.
    func testKnobIsVisibleAgainstBothTracks() throws {
        try sweep { theme, appearance, surface, isEnabled in
            let colors = try XCTUnwrap(
                ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: isEnabled)
            )
            let floor = isEnabled
                ? ThemeControlColors.componentMinimumRatio
                : ThemeControlColors.disabledMinimumRatio
            let context = label(theme, appearance, surface, isEnabled)
            assertRatio(colors.offKnob, colors.offTrack, atLeast: floor, "off knob vs off track", context)
            assertRatio(colors.onKnob, colors.onTrack, atLeast: floor, "on knob vs on track", context)
        }
    }

    /// On and off must not be tellable apart only by someone who can compare
    /// two hues. See `stateSeparationMinimumRatio` for why this bar is 2:1 and
    /// not 3:1.
    func testOnAndOffAreDistinguishableFromEachOther() throws {
        try sweep { theme, appearance, surface, isEnabled in
            let colors = try XCTUnwrap(
                ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: isEnabled)
            )
            assertRatio(
                colors.offTrack, colors.onTrack,
                atLeast: ThemeControlColors.stateSeparationMinimumRatio(isEnabled: isEnabled),
                "off track vs on track",
                label(theme, appearance, surface, isEnabled)
            )
        }
    }

    /// Disabled has to look disabled. The floors alone cannot express this —
    /// they are lower bounds, and a derivation that ignored `isEnabled`
    /// entirely would pass every test above. This is the upper bound that
    /// makes the disabled state a real state.
    func testDisabledSwitchesAreVisiblyWeakerThanEnabledOnes() throws {
        for theme in Theme.builtInPresets {
            for appearance in ThemeAppearance.allCases {
                for surface in ThemeControlColors.hostSurfaces {
                    let enabled = try XCTUnwrap(
                        ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: true)
                    )
                    let disabled = try XCTUnwrap(
                        ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface, isEnabled: false)
                    )
                    let context = "\(theme.name) / \(appearance.rawValue) / on \(surface.rawValue)"

                    let enabledBorder = ThemeContrast.ratio(enabled.offBorder, enabled.backdrop)
                    let disabledBorder = ThemeContrast.ratio(disabled.offBorder, disabled.backdrop)
                    XCTAssertLessThan(
                        disabledBorder, enabledBorder,
                        "\(context): the disabled off-border (\(ThemeContrast.format(disabledBorder))) is not weaker "
                            + "than the enabled one (\(ThemeContrast.format(enabledBorder))) — disabled does not read as disabled."
                    )
                }
            }
        }
    }

    // MARK: - Material themes

    /// Any preset that draws over an `NSVisualEffectView` must still be
    /// graded, and must be graded through a stated assumption rather than by
    /// pretending its alpha is 1 — which would *overstate* contrast and let
    /// an invisible switch pass.
    ///
    /// Asserts the flag rather than the number: what matters is that the
    /// approximation is admitted exactly where it is made, and — just as
    /// importantly — *not* claimed where it isn't.
    ///
    /// **The subtlety this test exists to pin down.** "Material theme" does not
    /// mean "every surface is a guess". System draws a translucent
    /// `background` (alpha 0.85) and a translucent `surface` (`#0000000A`), so
    /// both of those resolve through the assumed desktop and are honestly
    /// approximate. But its `surfaceElevated` is `#F5F5F7`, fully opaque — a
    /// solid card sitting on top of the blur, hiding it completely. The
    /// backdrop for a switch on that card is therefore *known exactly*, and
    /// flagging it approximate would be the mirror of the error this whole
    /// file guards against: crying uncertainty about a number that is certain.
    /// The first draft of this test asserted "material ⇒ approximate" and
    /// failed on precisely that case, which is the code being right.
    ///
    /// Expectation is computed from the presets' own alphas rather than
    /// hardcoded, so retuning a preset's opacity updates the expectation with
    /// it instead of turning this into a puzzle.
    func testMaterialThemeBackdropsAreApproximateExactlyWhenTranslucent() throws {
        for theme in Theme.builtInPresets.filter(\.useMaterialBackground) {
            for appearance in ThemeAppearance.allCases {
                for surface in ThemeControlColors.hostSurfaces {
                    let colors = try XCTUnwrap(
                        ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface)
                    )
                    let context = "\(theme.name) / \(appearance.rawValue) / \(surface.rawValue)"

                    // Opaque at this layer ⇒ nothing beneath it is visible ⇒
                    // nothing has to be assumed.
                    let ownAlpha = try XCTUnwrap(theme[surface].rgba(for: appearance)).alpha
                    let pageAlpha = try XCTUnwrap(theme.background.rgba(for: appearance)).alpha
                    let expected = ownAlpha < 0.999 && (surface == .background || pageAlpha < 0.999)

                    XCTAssertEqual(
                        colors.backdropIsApproximate, expected,
                        "\(context): backdropIsApproximate was \(colors.backdropIsApproximate) but this layer's "
                            + "own alpha is \(ownAlpha) over a page at alpha \(pageAlpha)."
                    )
                    XCTAssertEqual(
                        colors.backdrop.alpha, 1.0, accuracy: 0.0001,
                        "\(context): the resolved backdrop must be opaque before any ratio is taken."
                    )
                }
            }
        }
    }

    /// The half of the above worth stating on its own, because it is the
    /// dangerous direction: a translucent layer must never come back exact.
    /// Silently treating alpha as 1 *overstates* contrast, so a switch would
    /// pass this sweep and still disappear over a bright desktop.
    func testTranslucentLayersAreNeverReportedExact() throws {
        for theme in Theme.builtInPresets.filter(\.useMaterialBackground) {
            for appearance in ThemeAppearance.allCases {
                for surface in ThemeControlColors.hostSurfaces {
                    let ownAlpha = try XCTUnwrap(theme[surface].rgba(for: appearance)).alpha
                    guard ownAlpha < 0.999 else { continue }
                    let pageAlpha = try XCTUnwrap(theme.background.rgba(for: appearance)).alpha
                    guard surface == .background || pageAlpha < 0.999 else { continue }

                    let colors = try XCTUnwrap(
                        ThemeControlColors(theme: theme, appearance: appearance, backdrop: surface)
                    )
                    XCTAssertTrue(
                        colors.backdropIsApproximate,
                        "\(theme.name) / \(appearance.rawValue) / \(surface.rawValue): a layer at alpha "
                            + "\(ownAlpha) reported an exact backdrop — alpha was silently assumed to be 1."
                    )
                }
            }
        }
    }

    func testOpaqueThemesReportExactBackdrops() throws {
        for appearance in ThemeAppearance.allCases {
            for surface in ThemeControlColors.hostSurfaces {
                let colors = try XCTUnwrap(
                    ThemeControlColors(theme: .ivory, appearance: appearance, backdrop: surface)
                )
                XCTAssertFalse(
                    colors.backdropIsApproximate,
                    "Ivory / \(appearance.rawValue) / \(surface.rawValue): an opaque theme should need no assumption."
                )
            }
        }
    }

    // MARK: - The original failure, pinned

    /// The specific measurement from the bug report, kept as a regression
    /// anchor: AppKit's off-track grey against Ivory's card.
    ///
    /// `#E9E9EB` is the light-appearance system switch off-track. Against
    /// Ivory's `surfaceElevated` (`#E6E3D8`, the Keep Awake card) it measures
    /// about 1.05:1 — which is the report, quantified: not "low contrast" but
    /// *no* contrast. If someone ever reverts to the stock control, this test
    /// is the one that explains why the number matters.
    func testStockAppKitOffTrackWouldFailOnIvory() throws {
        let stockOffTrack = try XCTUnwrap(ThemeColor(light: "#E9E9EB", dark: "#E9E9EB").rgba(for: .light))
        let ivoryCard = try XCTUnwrap(Theme.ivory.surfaceElevated.rgba(for: .light))

        let stockRatio = ThemeContrast.ratio(stockOffTrack, ivoryCard)
        XCTAssertLessThan(
            stockRatio, 1.2,
            "The stock off-track was supposed to be invisible on Ivory; it measured \(ThemeContrast.format(stockRatio))."
        )

        let themed = try XCTUnwrap(
            ThemeControlColors(theme: .ivory, appearance: .light, backdrop: .surfaceElevated)
        )
        assertRatio(
            themed.offBorder, themed.backdrop,
            atLeast: ThemeControlColors.componentMinimumRatio,
            "the replacement's off-border vs Ivory's card",
            "Ivory / light / surfaceElevated / enabled"
        )
    }

    /// A preset whose tokens already clear the floor is drawn verbatim rather
    /// than restyled — the discipline `WatchPalette` settled on, applied here.
    /// Ivory's `#C96442` accent measures ~3.7:1 on its own surface, so the on
    /// track must come back as exactly that colour and not as a "safer" one.
    func testAlreadyPassingTokensAreNotRestyled() throws {
        let colors = try XCTUnwrap(
            ThemeControlColors(theme: .ivory, appearance: .light, backdrop: .surface)
        )
        let accent = try XCTUnwrap(Theme.ivory.accent.rgba(for: .light))
        XCTAssertEqual(colors.onTrack.red, accent.red, accuracy: 0.001)
        XCTAssertEqual(colors.onTrack.green, accent.green, accuracy: 0.001)
        XCTAssertEqual(colors.onTrack.blue, accent.blue, accuracy: 0.001)
    }
}
