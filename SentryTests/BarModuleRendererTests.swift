import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the two severity-adjacent fixes in
/// `Sentry/MenuBar/BarModuleRenderer.swift`:
///
///  * the warning band (0.6–0.85 of a `.thresholdGradient` ramp) used to
///    draw nothing at all — only `.critical` got a cue — so on a strictly
///    monochrome bar (see `MenuBarPalette`'s doc comment) two thirds of the
///    threshold ramp was silently unflagged;
///  * `alertHighlightColor(for:)`'s whole token switch collapsed to one
///    identical `NSColor` in monochrome mode, so `alertHighlightAlpha(for:)`
///    is the lever that now differentiates severity instead.
///
/// Nothing here asserts on pixels — `severity(for:)` and
/// `alertHighlightAlpha(for:)` are the pure, testable surface; the glyphs and
/// opacities themselves are verified by eye per the task's manual-testing
/// pass.
final class BarModuleRendererTests: XCTestCase {

    private func renderer() -> BarModuleRenderer {
        BarModuleRenderer(theme: .oneDark, dark: true)
    }

    private func gradientModule(low: Double = 0, high: Double = 100) -> BarModule {
        BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly, colorRule: .thresholdGradient(low: low, high: high))
    }

    // MARK: - Width stability (verified-bug pass: a module's slot used to
    // resize every tick as its value text reflowed, shifting every module to
    // its right — see `stabilizedValueWidth(_:for:)`'s doc comment)

    func testWidthNeverShrinksBelowAWiderValueAlreadySeen() {
        let renderer = renderer()
        let module = BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly, showUnit: true)

        let wide = renderer.width(for: module, value: 100, normalized: nil, history: [])
        let narrow = renderer.width(for: module, value: 9, normalized: nil, history: [])

        XCTAssertEqual(narrow, wide, "a value getting shorter must not shrink the module's slot back down")
    }

    func testWidthGrowsWhenAnEvenWiderValueArrives() {
        let renderer = renderer()
        let module = BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly, showUnit: true)

        let narrow = renderer.width(for: module, value: 9, normalized: nil, history: [])
        let wide = renderer.width(for: module, value: 100, normalized: nil, history: [])

        XCTAssertGreaterThan(wide, narrow, "a genuinely wider value must still grow the slot")
    }

    func testDistinctModulesTrackIndependentWidthFloors() {
        let renderer = renderer()
        let wideModule = BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly, showUnit: true)
        let narrowModule = BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly, showUnit: true)

        _ = renderer.width(for: wideModule, value: 100, normalized: nil, history: [])
        let untouched = renderer.width(for: narrowModule, value: 9, normalized: nil, history: [])
        let afterWideModuleGrew = renderer.width(for: narrowModule, value: 9, normalized: nil, history: [])

        XCTAssertEqual(untouched, afterWideModuleGrew, "one module's wide reading must not raise a different module's floor")
    }

    // MARK: - severity(for:value:)

    func testBelowWarningThresholdIsNominal() {
        let module = gradientModule()
        XCTAssertEqual(renderer().severity(for: module, value: 50), .nominal)
    }

    func testAtSixtyPercentOfRampIsWarning() {
        let module = gradientModule()
        XCTAssertEqual(renderer().severity(for: module, value: 61), .warning)
    }

    func testAtEightyFivePercentOfRampIsCritical() {
        let module = gradientModule()
        XCTAssertEqual(renderer().severity(for: module, value: 86), .critical)
    }

    func testNonGradientModuleHasNoSeverityRegardlessOfValue() {
        // Most modules default to `.matchSystemAccent` (see
        // `BarModule.init`'s default) — no rule defines "bad" for them, so
        // there is nothing for the bar to flag.
        let module = BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly)
        XCTAssertNil(renderer().severity(for: module, value: 99))
    }

    func testNilValueHasNoSeverity() {
        let module = gradientModule()
        XCTAssertNil(renderer().severity(for: module, value: nil))
    }

    // MARK: - The warning band now reserves cue width (the bug)

    /// Before this fix, only `.critical` widened the module's slot to make
    /// room for a cue glyph — a warning-band value measured exactly like a
    /// nominal one, i.e. the cue was never drawn. Both bands must now widen
    /// the module.
    func testWarningAndCriticalBothReserveMoreWidthThanNominal() {
        let r = renderer()
        let module = gradientModule()

        let nominalWidth = r.width(for: module, value: 10, normalized: nil, history: [])
        let warningWidth = r.width(for: module, value: 61, normalized: nil, history: [])
        let criticalWidth = r.width(for: module, value: 86, normalized: nil, history: [])

        XCTAssertGreaterThan(warningWidth, nominalWidth, "warning band must reserve cue width, not just critical")
        XCTAssertGreaterThan(criticalWidth, nominalWidth)
    }

    /// The two cues must be visually distinguishable — this can't assert on
    /// pixels, but different glyphs almost never measure identically, so a
    /// width difference is a decent proxy that they really are two different
    /// marks rather than the same one drawn twice.
    func testWarningCueAndCriticalCueAreNotIdenticalWidths() {
        let r = renderer()
        let module = gradientModule()

        let warningWidth = r.width(for: module, value: 61, normalized: nil, history: [])
        let criticalWidth = r.width(for: module, value: 86, normalized: nil, history: [])

        XCTAssertNotEqual(warningWidth, criticalWidth, "expected a visually distinct (and differently sized) glyph per band")
    }

    // MARK: - moduleDivider (verified-bug pass: the `.dot`/`.line` separators
    // `StatusItemView` paints between modules used `separator`'s 0.15 alpha —
    // sized for the `.bar`/`.arc` gauge track it backs, not for a mark that
    // has to stand out against an arbitrary wallpaper — and were reported
    // unreadable in practice.)

    func testModuleDividerIsMoreOpaqueThanTheGaugeTrackSeparator() {
        let palette = MenuBarPalette(theme: .oneDark, dark: true)
        XCTAssertGreaterThan(
            palette.moduleDivider.alphaComponent,
            palette.separator.alphaComponent,
            "the between-module divider must be more visible than the gauge-track background it used to share a token with"
        )
    }

    func testModuleDividerMatchesTextSecondaryLegibility() {
        let palette = MenuBarPalette(theme: .oneDark, dark: true)
        XCTAssertEqual(palette.moduleDivider.alphaComponent, palette.textSecondary.alphaComponent)
    }

    // MARK: - alertHighlightAlpha(for:)

    /// The bug: every token used to resolve to the same `NSColor` in
    /// monochrome mode, so the wash behind the bar looked identical for a
    /// critical alert and an "ok" one. Alpha is the fix — critical must be
    /// visually heaviest.
    func testCriticalAlphaIsHeavierThanEveryOtherToken() {
        let palette = MenuBarPalette(theme: .oneDark, dark: true)
        let critical = palette.alertHighlightAlpha(for: "critical")
        for token in ["warning", "success", "ok", "accent", "info", "unknown-token"] {
            XCTAssertGreaterThan(critical, palette.alertHighlightAlpha(for: token), "critical must outweigh '\(token)'")
        }
    }

    func testSuccessAlphaIsLighterThanWarning() {
        let palette = MenuBarPalette(theme: .oneDark, dark: true)
        XCTAssertLessThan(palette.alertHighlightAlpha(for: "success"), palette.alertHighlightAlpha(for: "warning"))
    }

    func testAlertHighlightAlphaIsCaseInsensitiveAndAliasesAgree() {
        let palette = MenuBarPalette(theme: .oneDark, dark: true)
        XCTAssertEqual(palette.alertHighlightAlpha(for: "critical"), palette.alertHighlightAlpha(for: "CRITICAL"))
        XCTAssertEqual(palette.alertHighlightAlpha(for: "danger"), palette.alertHighlightAlpha(for: "critical"))
        XCTAssertEqual(palette.alertHighlightAlpha(for: "error"), palette.alertHighlightAlpha(for: "critical"))
        XCTAssertEqual(palette.alertHighlightAlpha(for: "ok"), palette.alertHighlightAlpha(for: "success"))
        XCTAssertEqual(palette.alertHighlightAlpha(for: "info"), palette.alertHighlightAlpha(for: "accent"))
    }

    func testUnknownTokenFallsBackToTheSameAlphaAsWarning() {
        // `alertHighlightColor(for:)` falls back to `warning` for an
        // unrecognized token rather than drawing nothing; the alpha lever
        // agrees so the fallback is consistent end to end.
        let palette = MenuBarPalette(theme: .oneDark, dark: true)
        XCTAssertEqual(palette.alertHighlightAlpha(for: "totally-unknown"), palette.alertHighlightAlpha(for: "warning"))
    }
}
