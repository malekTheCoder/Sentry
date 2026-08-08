import XCTest
@testable import SentryKit

/// Plan §9.4's contrast checker, verified against WCAG's own published pairs.
///
/// **Why the expected numbers are hard-coded rather than derived.** A test
/// that recomputes the ratio with the same formula the implementation uses
/// proves only that the code is self-consistent — it would pass just as
/// happily with the exponent wrong. Every constant below was produced
/// independently (WebAIM's contrast checker and the WCAG 2.1 formula worked
/// by hand), so a change to `ThemeContrast` that silently alters the curve
/// fails here.
///
/// `#767676 on #FFFFFF = 4.54` is the pair worth knowing: it is the canonical
/// "just barely passes AA" gray, and `#777777` one shade lighter is 4.48 and
/// fails. A checker that can't tell those two apart can't do its job.
final class ThemeContrastTests: XCTestCase {

    private func rgba(_ hex: String, opacity: Double = 1) -> ThemeColor.RGBA {
        guard let parsed = ThemeColor(hex: hex, opacity: opacity).rgba(for: .light) else {
            XCTFail("fixture hex \(hex) failed to parse")
            return ThemeColor.RGBA(red: 0, green: 0, blue: 0)
        }
        return parsed
    }

    private func ratio(_ a: String, _ b: String) -> Double {
        ThemeContrast.ratio(rgba(a), rgba(b))
    }

    // MARK: - Known WCAG pairs

    func testBlackOnWhiteIsTheMaximumRatio() {
        XCTAssertEqual(ratio("#000000", "#FFFFFF"), 21.0, accuracy: 0.001)
        // Order must not matter: the formula sorts by luminance itself.
        XCTAssertEqual(ratio("#FFFFFF", "#000000"), 21.0, accuracy: 0.001)
    }

    func testIdenticalColorsAreOneToOne() {
        XCTAssertEqual(ratio("#4C8BF5", "#4C8BF5"), 1.0, accuracy: 0.0001)
    }

    func testCanonicalAAGrayPassesAndOneShadeLighterFails() {
        let passes = ratio("#767676", "#FFFFFF")
        let fails = ratio("#777777", "#FFFFFF")
        XCTAssertEqual(passes, 4.5422, accuracy: 0.001)
        XCTAssertEqual(fails, 4.4781, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(passes, ContrastRequirement.textAA.minimumRatio)
        XCTAssertLessThan(fails, ContrastRequirement.textAA.minimumRatio)
    }

    func testPrimaryColorsAgainstWhite() {
        XCTAssertEqual(ratio("#0000FF", "#FFFFFF"), 8.5925, accuracy: 0.001)
        XCTAssertEqual(ratio("#FF0000", "#FFFFFF"), 3.9985, accuracy: 0.001)
        XCTAssertEqual(ratio("#949494", "#FFFFFF"), 3.0335, accuracy: 0.001)
        XCTAssertEqual(ratio("#595959", "#FFFFFF"), 7.0047, accuracy: 0.001)
    }

    func testMidGrayOnBlack() {
        XCTAssertEqual(ratio("#808080", "#000000"), 5.3172, accuracy: 0.001)
    }

    /// The transfer function's own kink. Below 0.03928 the curve is linear;
    /// a implementation that used the exponent everywhere would drift here.
    func testLinearizeUsesTheLinearSegmentForVeryDarkChannels() {
        XCTAssertEqual(ThemeContrast.linearize(0.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(ThemeContrast.linearize(0.02), 0.02 / 12.92, accuracy: 1e-12)
        XCTAssertEqual(ThemeContrast.linearize(1.0), 1.0, accuracy: 1e-9)
    }

    func testRelativeLuminanceWeightsGreenMostAndBlueLeast() {
        let red = ThemeContrast.relativeLuminance(rgba("#FF0000"))
        let green = ThemeContrast.relativeLuminance(rgba("#00FF00"))
        let blue = ThemeContrast.relativeLuminance(rgba("#0000FF"))
        XCTAssertEqual(red, 0.2126, accuracy: 1e-6)
        XCTAssertEqual(green, 0.7152, accuracy: 1e-6)
        XCTAssertEqual(blue, 0.0722, accuracy: 1e-6)
    }

    // MARK: - Compositing

    /// A 50%-opacity black text token over white is *not* the same as a
    /// mid-gray-on-white ratio computed from the raw hex — which is exactly
    /// the mistake an auditor that ignored `ThemeColor.opacity` would make,
    /// and it would report 21:1 for a token that actually reads at 3.98:1.
    func testOpacityIsCompositedBeforeMeasuring() {
        let white = rgba("#FFFFFF")
        let halfBlack = rgba("#000000", opacity: 0.5)
        let composited = ThemeContrast.flatten(halfBlack, onto: white)
        XCTAssertEqual(ThemeContrast.ratio(composited, white), 3.9767, accuracy: 0.001)

        // Naively ignoring alpha would have claimed the maximum.
        XCTAssertEqual(ThemeContrast.ratio(rgba("#000000"), white), 21.0, accuracy: 0.001)
    }

    func testFullyTransparentForegroundDisappearsIntoItsBackdrop() {
        let backdrop = rgba("#123456")
        let ghost = rgba("#FFFFFF", opacity: 0)
        let composited = ThemeContrast.flatten(ghost, onto: backdrop)
        XCTAssertEqual(ThemeContrast.ratio(composited, backdrop), 1.0, accuracy: 0.0001)
    }

    func testHexAlphaByteIsHonoredAlongsideTheOpacityMultiplier() {
        // #00000080 is 50% alpha in the hex itself; opacity 0.5 halves it
        // again to 25%, which must land between the 50% and 0% cases above.
        let color = ThemeColor(hex: "#00000080", opacity: 0.5)
        guard let parsed = color.rgba(for: .light) else { return XCTFail("parse failed") }
        XCTAssertEqual(parsed.alpha, 0.25, accuracy: 0.005)
    }

    // MARK: - Hex parsing

    func testShorthandAndLonghandHexAgree() {
        XCTAssertEqual(ThemeColor.components(fromHex: "#F00"), ThemeColor.components(fromHex: "#FF0000"))
        XCTAssertEqual(ThemeColor.components(fromHex: "abc"), ThemeColor.components(fromHex: "#AABBCC"))
    }

    func testMalformedHexReturnsNilRatherThanGuessing() {
        for bad in ["", "#", "#GGGGGG", "#12345", "#1234567", "rgb(0,0,0)", "   "] {
            XCTAssertNil(ThemeColor.components(fromHex: bad), "expected \(bad) to be rejected")
        }
    }

    // MARK: - Audit

    /// The invariant that *is* true today, and the one that matters most:
    /// the token carrying every actual readout passes AA on every surface, in
    /// both appearances, in every preset.
    func testPrimaryTextPassesAAInEveryPreset() {
        for preset in Theme.builtInPresets {
            let failures = preset.contrastAudit
                .failures(for: .textPrimary)
                .filter { $0.requirement == .textAA }
            XCTAssertTrue(
                failures.isEmpty,
                "\(preset.name): " + failures.map(\.summary).joined(separator: " | ")
            )
        }
    }

    /// **A documented gap, asserted so it can't widen silently.**
    ///
    /// Plan §9.4 says "Every preset must pass WCAG AA (4.5:1) for text
    /// tokens." Running the checker against the shipped presets shows that
    /// claim is not true today — each has at least one text token below
    /// 4.5:1, most commonly `textTertiary` (timestamps and disabled text,
    /// deliberately faint in every preset) and, in the halves that predate
    /// the light/dark pairing, semantic colors on `surfaceElevated`.
    ///
    /// This test deliberately does **not** assert the requirement and fail.
    /// Making the shipped halves pass is a palette redesign with a visual
    /// review attached (Tokyo Night's dark half is a reproduction of a
    /// published palette; the faint tertiary ramp is a deliberate design
    /// choice) — this test is the instrument that measures the gap, not the
    /// fix.
    ///
    /// What is asserted is the *shape* of the gap: which tokens are
    /// responsible. If a future edit drops `textPrimary` below AA, or fixes
    /// the tertiary ramp everywhere, this test fails and someone has to look.
    func testShippedPresetsDoNotYetMeetSection94AndTheGapIsWhereWeThinkItIs() {
        var failingTokens: Set<ThemeColorToken> = []
        var failingPresets: Set<String> = []

        for preset in Theme.builtInPresets {
            for finding in preset.contrastAudit.findings
            where finding.requirement == .textAA && !finding.passes {
                failingPresets.insert(preset.name)
                if case .token(let token) = finding.subject { failingTokens.insert(token) }
            }
        }

        XCTAssertFalse(
            failingTokens.contains(.textPrimary),
            "primary text must never be the token that fails — see the test above"
        )
        XCTAssertEqual(
            failingTokens,
            [.textSecondary, .textTertiary, .accent, .success, .warning, .danger],
            "the set of tokens responsible for §9.4's shortfall changed; re-read the presets"
        )
        XCTAssertEqual(
            failingPresets.count,
            Theme.builtInPresets.count,
            "every shipped preset currently has at least one sub-AA text pair; if that changed, update this test and the note in ThemePane"
        )
    }

    func testAuditCoversBothAppearancesAndEverySurface() {
        let audit = Theme.system.contrastAudit
        for appearance in ThemeAppearance.allCases {
            for backdrop in ThemeContrastAudit.auditedBackdrops {
                for token in ThemeContrastAudit.auditedTextTokens {
                    XCTAssertTrue(
                        audit.findings.contains {
                            $0.subject == .token(token)
                                && $0.backdrop == backdrop
                                && $0.appearance == appearance
                        },
                        "no finding for \(token.rawValue) on \(backdrop.rawValue) in \(appearance.rawValue)"
                    )
                }
            }
        }
    }

    func testUnreadableTextIsFlaggedRatherThanScored() {
        var theme = Theme.system.duplicated(named: "Invisible")
        // The classic unreadable theme: text the same color as its backdrop.
        theme.background = ThemeColor(hex: "#202020")
        theme.surface = ThemeColor(hex: "#202020")
        theme.surfaceElevated = ThemeColor(hex: "#202020")
        theme.textPrimary = ThemeColor(hex: "#202020")

        let audit = theme.contrastAudit
        XCTAssertFalse(audit.passesTextAA)

        let primaryFailures = audit.failures(for: .textPrimary)
        XCTAssertFalse(primaryFailures.isEmpty)
        for finding in primaryFailures where finding.appearance == .dark {
            XCTAssertEqual(finding.ratio ?? 0, 1.0, accuracy: 0.0001)
        }
    }

    func testMalformedColorProducesNoRatioAndDoesNotPass() {
        var theme = Theme.system.duplicated(named: "Broken")
        theme.textPrimary = ThemeColor(hex: "#NOTAHEX")

        let findings = theme.contrastAudit.findings.filter { $0.subject == .token(.textPrimary) }
        XCTAssertFalse(findings.isEmpty)
        for finding in findings {
            XCTAssertNil(finding.ratio, "an unparseable color must not be scored")
            XCTAssertTrue(finding.isUnreadable)
            XCTAssertFalse(finding.passes, "an unreadable color must never count as passing")
        }
    }

    func testTranslucentBackdropIsMarkedApproximate() {
        // Translucent's background is 35% opacity — the app cannot know what
        // is behind it, and the finding has to say so.
        let audit = Theme.translucent.contrastAudit
        let backgroundFindings = audit.findings.filter { $0.backdrop == .background }
        XCTAssertFalse(backgroundFindings.isEmpty)
        XCTAssertTrue(backgroundFindings.allSatisfy(\.backdropIsApproximate))

        // An opaque theme's findings must not be labelled approximate, or
        // the caveat stops meaning anything.
        let opaque = Theme.oneDark.contrastAudit.findings.filter { $0.backdrop == .background }
        XCTAssertFalse(opaque.isEmpty)
        XCTAssertFalse(opaque.contains(where: \.backdropIsApproximate))
    }

    func testMetricColorsAreHeldToTheNonTextThreshold() {
        let audit = Theme.system.contrastAudit
        let metricFindings = audit.findings.filter {
            if case .metric = $0.subject { return true }
            return false
        }
        XCTAssertFalse(metricFindings.isEmpty)
        XCTAssertTrue(metricFindings.allSatisfy { $0.requirement == .nonText })
        XCTAssertEqual(ContrastRequirement.nonText.minimumRatio, 3.0)
        XCTAssertEqual(ContrastRequirement.textAA.minimumRatio, 4.5)
    }

    func testUnknownMetricKeysAreAuditedRatherThanSkipped() {
        var theme = Theme.system.duplicated(named: "Odd keys")
        theme.metricColors["not.a.real.metric"] = ThemeColor(hex: "#191919")

        let audit = theme.contrastAudit
        let findings = audit.findings.filter { $0.subject == .unknownMetric("not.a.real.metric") }
        XCTAssertFalse(findings.isEmpty, "an unrecognised key must still be checked, not silently dropped")
    }

    func testFindingIdentifiersAreUnique() {
        // The editor puts these in `ForEach`; a collision would silently drop
        // rows from the issue list.
        let ids = Theme.system.contrastAudit.findings.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testWorstRatioReportsTheLowestNotTheFirst() {
        var theme = Theme.system.duplicated(named: "Uneven")
        theme.background = ThemeColor(hex: "#FFFFFF")
        theme.surface = ThemeColor(hex: "#FFFFFF")
        theme.surfaceElevated = ThemeColor(hex: "#767676")
        theme.textPrimary = ThemeColor(hex: "#000000")

        let audit = theme.contrastAudit
        guard let worst = audit.worstRatio(for: .token(.textPrimary)) else {
            return XCTFail("expected a ratio")
        }
        // Black on #767676 is far tighter than black on white; the badge must
        // show the tighter one.
        XCTAssertLessThan(worst, 21.0)
        XCTAssertEqual(worst, ThemeContrast.ratio(rgba("#000000"), rgba("#767676")), accuracy: 0.001)
    }

    func testHeadlineDistinguishesPassFromFailure() {
        // Built from scratch rather than forked from a preset: as the gap
        // test above records, no shipped preset currently passes, so there is
        // no preset to use as the "passes" fixture.
        var clean = Theme.system.duplicated(named: "Clean")
        clean.background = ThemeColor(hex: "#FFFFFF")
        clean.surface = ThemeColor(hex: "#FFFFFF")
        clean.surfaceElevated = ThemeColor(hex: "#FFFFFF")
        for token in ThemeContrastAudit.auditedTextTokens {
            clean[token] = ThemeColor(hex: "#000000")
        }
        XCTAssertTrue(clean.contrastAudit.passesTextAA)
        XCTAssertTrue(clean.contrastAudit.headline.contains("passes"))

        var broken = clean
        broken.textPrimary = broken.background
        XCTAssertFalse(broken.contrastAudit.passesTextAA)
        XCTAssertNotEqual(broken.contrastAudit.headline, clean.contrastAudit.headline)
    }
}
