import XCTest
@testable import SentryKit

/// The sweep that proves every built-in theme renders legibly on the wrist —
/// `ThemedControlContrastTests`' discipline applied to the watch's own
/// controls, graded on the bytes `WatchThemeColors` hands `WatchPalette`.
///
/// **What was wrong.** `StatusPill` and `WatchActionButtonStyle`
/// (`SentryWatch/Views/WatchCard.swift`) draw a theme token as an 18% wash
/// and then draw the same token as the label on top of it. On every dark
/// half that pairing is comfortably readable. On a light half it is not:
/// System's `success` over its own wash measured about 1.8:1 — the "Live"
/// freshness pill on the default theme, pale green on pale green — and
/// Ivory's `accent`, `success` and `warning` sat in the 2.6–2.9 range. Nothing
/// crashed, nothing looked broken in a dark screenshot, and the
/// light-appearance case had only ever been eyeballed. This file is the
/// test the Mac's switch work said a claim like "renders correctly" needs
/// before it is made.
///
/// **Why the sweep is over `Theme.builtInPresets`, not a literal list.** The
/// preset list has changed before and will again; a test that names Ivory
/// and One Dark grades the day's presets and nothing added tomorrow.
final class WatchControlContrastTests: XCTestCase {

    // MARK: - Helpers

    private func sweep(
        _ body: (Theme, ThemeAppearance, WatchThemeColors) throws -> Void
    ) rethrows {
        for theme in Theme.builtInPresets {
            for appearance in ThemeAppearance.allCases {
                try body(theme, appearance, WatchThemeColors(theme: theme, appearance: appearance))
            }
        }
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

    private func context(_ theme: Theme, _ appearance: ThemeAppearance, _ extra: String = "") -> String {
        "\(theme.name) / \(appearance.rawValue)" + (extra.isEmpty ? "" : " / \(extra)")
    }

    // MARK: - The canvas

    /// The page is the one layer with nothing of the theme's beneath it, so
    /// it has to come back opaque — otherwise the black watch window shows
    /// through and every ratio below is graded against the wrong colour.
    func testEveryPresetResolvesAnOpaqueCanvasInBothAppearances() {
        sweep { theme, appearance, colors in
            XCTAssertEqual(
                colors.canvas.alpha, 1.0, accuracy: 0.0001,
                "\(context(theme, appearance)): the canvas must be opaque before anything is graded on it."
            )
        }
    }

    /// The bug the flatten exists for, pinned: System's light `background`
    /// is white at 85% alpha, and over the watch's black window that is a
    /// mid grey (`#D9D9D9`, ~0.7 relative luminance) rather than the white
    /// the phone shows under the same theme. Flattened onto the assumed
    /// light backdrop it is white, which is what "matches my phone" means.
    func testSystemLightCanvasIsWhiteNotTheGreyTheBlackWindowWouldMakeIt() throws {
        let raw = try XCTUnwrap(Theme.system.background.rgba(for: .light))
        XCTAssertLessThan(raw.alpha, 0.999, "System's light background is expected to be translucent")

        let overBlack = ThemeContrast.flatten(raw, onto: ThemeContrast.assumedBackdrop(for: .dark))
        XCTAssertLessThan(
            ThemeContrast.relativeLuminance(overBlack), 0.75,
            "over the black watch window System's light canvas would be a visible grey"
        )

        let canvas = WatchThemeColors(theme: .system, appearance: .light).canvas
        XCTAssertGreaterThan(ThemeContrast.relativeLuminance(canvas), 0.99, "the resolved canvas must be white")
    }

    // MARK: - Text on the surfaces it is actually drawn on

    /// The readouts — every percentage, the device name, the countdown — are
    /// `textPrimary` on a card or on the canvas. WCAG AA text, both hosts,
    /// every preset, both halves. `WatchThemeFidelityTests` asserts this for
    /// Ivory's light half only; this is the same claim made for the set.
    func testPrimaryTextPassesAAOnBothHostsInEveryPreset() {
        sweep { theme, appearance, colors in
            for host in WatchThemeColors.Host.allCases {
                let backdrop = colors.backdrop(host)
                let text = ThemeContrast.flatten(colors.textPrimary, onto: backdrop)
                assertRatio(text, backdrop, atLeast: 4.5, "textPrimary", context(theme, appearance, "\(host)"))
            }
        }
    }

    // MARK: - Controls

    /// **The bug, asserted.** A control's label must clear the component
    /// floor against the control's own wash, on both hosts, in every preset
    /// and both halves — this is exactly what `StatusPill` and
    /// `WatchActionButtonStyle` draw.
    func testEveryControlLabelClearsTheFloorAgainstItsOwnFillOnBothHosts() {
        sweep { theme, appearance, colors in
            for role in WatchThemeColors.Role.allCases {
                let control = colors.control(role)
                for host in WatchThemeColors.Host.allCases {
                    assertRatio(
                        control.label, colors.controlFill(role, on: host),
                        atLeast: WatchThemeColors.controlLabelMinimumRatio,
                        "\(role) label vs its fill",
                        context(theme, appearance, "\(host)")
                    )
                }
            }
        }
    }

    /// The wash has to be a wash: a fill indistinguishable from its host
    /// would pass the label check above while turning the pill into
    /// floating text. Same 1.10 the Mac holds its off-track recess to.
    func testEveryControlFillIsDistinguishableFromItsHost() {
        sweep { theme, appearance, colors in
            for role in WatchThemeColors.Role.allCases {
                for host in WatchThemeColors.Host.allCases {
                    assertRatio(
                        colors.controlFill(role, on: host), colors.backdrop(host),
                        atLeast: WatchThemeColors.controlFillMinimumRatio,
                        "\(role) fill vs host",
                        context(theme, appearance, "\(host)")
                    )
                }
            }
        }
    }

    /// A token that already clears the floor is drawn verbatim — the
    /// discipline `WatchPalette` settled on and `ThemeControlColors` copied.
    /// Ivory's light `danger` is the anchor: `#BF4D43` measures 3.3:1
    /// against its own wash on a card, so it must come back untouched.
    ///
    /// Not Ivory's accent, which the first draft of this test named on the
    /// strength of its 3.7:1 against the bare surface: over its own 18%
    /// wash that drops to 2.76, and the sweep corrected the assumption
    /// before it reached a doc comment — which is the point of grading the
    /// fill the label actually sits on rather than the surface behind it.
    func testAnAlreadyLegibleTokenIsNotRestyled() throws {
        let colors = WatchThemeColors(theme: .ivory, appearance: .light)
        let control = colors.control(.danger)
        let danger = try XCTUnwrap(Theme.ivory.danger.rgba(for: .light))
        XCTAssertEqual(control.label.red, danger.red, accuracy: 0.001)
        XCTAssertEqual(control.label.green, danger.green, accuracy: 0.001)
        XCTAssertEqual(control.label.blue, danger.blue, accuracy: 0.001)
    }

    /// The counterpart, so a verbatim result cannot be mistaken for the
    /// repair never running: One Dark clears the floor everywhere as
    /// authored, so its light half must be untouched too — the same
    /// assertion `testDarkHalvesAreDrawnVerbatim` makes for the dark halves.
    func testOneDarksLightHalfIsDrawnVerbatim() {
        let colors = WatchThemeColors(theme: .oneDark, appearance: .light)
        for role in WatchThemeColors.Role.allCases {
            let control = colors.control(role)
            let verbatim = ThemeContrast.flatten(control.tint, onto: colors.backdrop(.card))
            XCTAssertEqual(control.label.red, verbatim.red, accuracy: 0.001, "One Dark / light / \(role)")
            XCTAssertEqual(control.label.green, verbatim.green, accuracy: 0.001, "One Dark / light / \(role)")
            XCTAssertEqual(control.label.blue, verbatim.blue, accuracy: 0.001, "One Dark / light / \(role)")
        }
    }

    /// The repair is narrow: every dark half already clears the floor as
    /// authored, so no dark-appearance label may be touched. If this ever
    /// fails, a preset's dark tokens changed, not this file.
    func testDarkHalvesAreDrawnVerbatim() {
        for theme in Theme.builtInPresets {
            let colors = WatchThemeColors(theme: theme, appearance: .dark)
            for role in WatchThemeColors.Role.allCases {
                let control = colors.control(role)
                let verbatim = ThemeContrast.flatten(control.tint, onto: colors.backdrop(.card))
                XCTAssertEqual(control.label.red, verbatim.red, accuracy: 0.001, "\(theme.name) / dark / \(role)")
                XCTAssertEqual(control.label.green, verbatim.green, accuracy: 0.001, "\(theme.name) / dark / \(role)")
                XCTAssertEqual(control.label.blue, verbatim.blue, accuracy: 0.001, "\(theme.name) / dark / \(role)")
            }
        }
    }

    // MARK: - The original failure, pinned

    /// The measurement that motivated `control(_:)`, kept as a regression
    /// anchor: System's `success` drawn verbatim over its own wash on a
    /// light card — the "Live" pill on the default theme — is under 2:1.
    /// If someone reverts the label to the raw token, this is the test that
    /// says what the number was.
    func testSystemsVerbatimSuccessLabelWouldHaveBeenUnderTwoToOne() {
        let colors = WatchThemeColors(theme: .system, appearance: .light)
        let fill = colors.controlFill(.success, on: .card)
        let verbatim = ThemeContrast.flatten(colors.success, onto: colors.backdrop(.card))

        let ratio = ThemeContrast.ratio(verbatim, fill)
        XCTAssertLessThan(
            ratio, 2.0,
            "System's verbatim success label was supposed to be illegible on its wash; it measured \(ThemeContrast.format(ratio))."
        )
        assertRatio(
            colors.control(.success).label, fill,
            atLeast: WatchThemeColors.controlLabelMinimumRatio,
            "the repaired success label vs its fill",
            "System / light / card"
        )
    }

    // MARK: - The relayed path draws the same bytes

    /// In production the phone sends `RelayedPalette` and the watch prefers
    /// it over the id lookup (`WatchPalette.relayed`). The two paths must
    /// resolve to the same colours for every preset, or a relayed Ivory
    /// would be graded here as one thing and drawn on the wrist as another.
    /// Tolerance is one hex byte: the relay quantises to `RRGGBB(AA)`.
    func testARelayedPaletteResolvesToTheSameColoursAsTheThemeItself() {
        sweep { theme, appearance, byID in
            let relayed = WatchThemeColors(
                theme: theme,
                appearance: appearance,
                relayed: RelayedPalette(theme: theme, appearance: appearance)
            )
            let pairs: [(String, ThemeColor.RGBA, ThemeColor.RGBA)] = [
                ("canvas", byID.canvas, relayed.canvas),
                ("surface", byID.surface, relayed.surface),
                ("textPrimary", byID.textPrimary, relayed.textPrimary),
                ("textSecondary", byID.textSecondary, relayed.textSecondary),
                ("accent", byID.accent, relayed.accent),
                ("success", byID.success, relayed.success),
                ("warning", byID.warning, relayed.warning),
                ("danger", byID.danger, relayed.danger),
                ("separator", byID.separator, relayed.separator),
            ]
            for (name, a, b) in pairs {
                let label = "\(context(theme, appearance)) / \(name)"
                XCTAssertEqual(a.red, b.red, accuracy: 1.0 / 255, label)
                XCTAssertEqual(a.green, b.green, accuracy: 1.0 / 255, label)
                XCTAssertEqual(a.blue, b.blue, accuracy: 1.0 / 255, label)
                XCTAssertEqual(a.alpha, b.alpha, accuracy: 1.0 / 255, label)
            }
            for role in WatchThemeColors.Role.allCases {
                let a = byID.control(role).label
                let b = relayed.control(role).label
                let label = "\(context(theme, appearance)) / \(role) label"
                XCTAssertEqual(a.red, b.red, accuracy: 2.0 / 255, label)
                XCTAssertEqual(a.green, b.green, accuracy: 2.0 / 255, label)
                XCTAssertEqual(a.blue, b.blue, accuracy: 2.0 / 255, label)
            }
        }
    }
}
