import XCTest
@testable import SentryKit

/// Covers `TypeScale.textStyle(forSize:)` (`SentryKit/Settings/Theme.swift`),
/// the pure half of the iPhone app's Dynamic Type support: which
/// `Font.TextStyle` a hand-tuned point size should scale relative to.
///
/// This is worth testing precisely because the rest of the feature isn't
/// testable here — the SwiftUI side is a `@ScaledMetric` modifier in the iOS
/// app target, which this macOS test bundle can't link. The mapping is the
/// part that decides whether a 32pt hero numeral grows by 30% or by 300%, and
/// it is ordinary arithmetic over a fixed table, so it gets ordinary tests.
final class TypeScaleTests: XCTestCase {
    // MARK: Anchors map to themselves

    func testEachAnchorSizeMapsToItsOwnStyle() {
        for anchor in TypeScale.anchors {
            XCTAssertEqual(
                TypeScale.textStyle(forSize: anchor.size),
                anchor.style,
                "\(anchor.size)pt should map to \(anchor.style)"
            )
        }
    }

    // MARK: The sizes this codebase actually uses

    /// Every literal point size passed to the iPhone app's typography API,
    /// with the style it must resolve to. Written out rather than derived so a
    /// change to the anchor table shows up here as a failing assertion naming
    /// the affected call site's size, not as a silently different app.
    func testSizesUsedByTheiPhoneApp() {
        let expected: [(CGFloat, TextStyleToken)] = [
            (8, .caption2),      // status pill bullet, info glyph
            (9, .caption2),      // disclosure-row outline circle
            (10, .caption2),     // section headers, button labels
            (10.5, .caption2),   // explanatory captions
            (11, .caption2),     // detail rows, chart legend
            (11.5, .caption2),   // notification category names
            (12, .caption),      // connection sentence, wattage
            (12.5, .caption),    // device / rule names
            (13, .footnote),     // card titles, module chips
            (14, .footnote),     // vitals row labels
            (20, .title3),       // tab titles, vitals headline numerals
            (24, .title2),       // keep-awake countdown
            (28, .title),        // Dashboard's Mac-name large title
            (32, .largeTitle),   // battery percentage hero
            (40, .largeTitle),   // stub-tab glyph
        ]
        for (size, style) in expected {
            XCTAssertEqual(TypeScale.textStyle(forSize: size), style, "size \(size)")
        }
    }

    // MARK: Tie-breaking

    /// 14pt is equidistant from `.footnote` (13) and `.subheadline` (15), and
    /// 11.5pt from `.caption2` (11) and `.caption` (12). Both must resolve
    /// downward — see `TypeScale`'s doc comment on why the smaller anchor is
    /// the safe direction for an accessibility feature.
    func testExactTiesResolveToTheSmallerStyle() {
        XCTAssertEqual(TypeScale.textStyle(forSize: 14), .footnote)
        XCTAssertEqual(TypeScale.textStyle(forSize: 11.5), .caption2)
        XCTAssertEqual(TypeScale.textStyle(forSize: 12.5), .caption)
        XCTAssertEqual(TypeScale.textStyle(forSize: 15.5), .subheadline)
    }

    // MARK: Saturation at both ends

    func testSizesBelowTheSmallestAnchorClampToCaption2() {
        for size in [CGFloat(0), 1, 4, 8, 10.9] {
            XCTAssertEqual(TypeScale.textStyle(forSize: size), .caption2, "size \(size)")
        }
    }

    /// The task that introduced this type names a 64pt hero number
    /// explicitly. Nothing in the app is that large today, but the mapping
    /// must not extrapolate past `.largeTitle` — there is no larger anchor,
    /// and `.largeTitle`'s gentle curve is what a display-size numeral wants.
    func testSizesAboveTheLargestAnchorClampToLargeTitle() {
        for size in [CGFloat(34), 40, 64, 120] {
            XCTAssertEqual(TypeScale.textStyle(forSize: size), .largeTitle, "size \(size)")
        }
    }

    // MARK: Monotonicity

    /// Sweeping the whole usable range in half-point steps, the chosen style
    /// must never go *backwards*. A non-monotonic mapping would mean some
    /// larger design size scaled like smaller text, which is the one way this
    /// table could be wrong without any individual case looking wrong.
    func testMappingIsMonotonicAcrossTheRange() {
        let order = TextStyleToken.allCases
        var previousIndex = 0
        var size: CGFloat = 0
        while size <= 60 {
            let index = order.firstIndex(of: TypeScale.textStyle(forSize: size))!
            XCTAssertGreaterThanOrEqual(index, previousIndex, "regressed at size \(size)")
            previousIndex = index
            size += 0.5
        }
    }

    /// `TextStyleToken.allCases` is relied on above as an ascending-size
    /// ordering, and `TypeScale.anchors` must agree with it — both are
    /// hand-maintained lists that would otherwise be free to drift apart.
    func testAnchorTableIsAscendingAndMatchesTokenOrder() {
        XCTAssertEqual(TypeScale.anchors.map(\.style), TextStyleToken.allCases)
        XCTAssertEqual(TypeScale.anchors.map(\.size), TypeScale.anchors.map(\.size).sorted())
    }
}
