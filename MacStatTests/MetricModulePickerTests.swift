import XCTest
@testable import MacStatKit

/// `MetricModulePicker` is the pure content model behind the iPhone History
/// tab's per-metric picker (`MacStatMobile/History/PerMetricHistoryBrowser.swift`),
/// and it exists in `MacStatKit` precisely so this macOS-hosted bundle can
/// reach it — the view itself lives in the `MacStatMobile` app target, which
/// is not importable from here (same constraint that moved
/// `SyntheticDailyHealth` into the framework; see its doc comment).
///
/// The bug these pin down: the picker used to be `.pickerStyle(.segmented)`
/// over all nine `MetricModule` cases. A `UISegmentedControl` splits its
/// width evenly, so nine segments got ~35pt each and the labels elided —
/// and critically **"Neural Engine" and "Network" both truncated to "Ne…"**,
/// making two different modules indistinguishable. So the invariants worth
/// asserting are: every module is still offered (the browser filters its
/// metric list by the selection, so a dropped module means unreachable
/// metrics), exactly one is selected, and the titles are the full
/// `displayName`s — never an abbreviation the renderer invented.
///
/// What these tests deliberately do *not* cover: the chip row's geometry —
/// that labels actually fit, at every Dynamic Type size, in every language.
/// That is a SwiftUI layout property of a view in another target, not
/// reachable from a macOS unit test bundle; it was verified in the iOS
/// Simulator instead. What is testable is the thing that makes truncation a
/// correctness bug rather than a cosmetic one, and that is asserted below.
final class MetricModulePickerTests: XCTestCase {

    func testEveryModuleIsOffered() {
        let items = MetricModulePicker.items(selected: .cpu)
        XCTAssertEqual(items.count, MetricModule.allCases.count)
        XCTAssertEqual(items.count, 9, "A tenth module needs a look at the picker's row width")
        XCTAssertEqual(items.map(\.module), MetricModule.allCases)
    }

    func testOrderIsDeclarationOrderNotLocalizedSortOrder() {
        // Pinned literally: the order must not depend on the device
        // language, or muscle memory and every screenshot become
        // locale-specific. See `MetricModulePicker.items(selected:)`.
        XCTAssertEqual(
            MetricModulePicker.items(selected: .battery).map(\.module),
            [.battery, .cpu, .gpu, .ane, .memory, .disk, .network, .thermal, .system]
        )
    }

    func testExactlyOneItemIsSelectedAndItIsTheRequestedOne() {
        for module in MetricModule.allCases {
            let items = MetricModulePicker.items(selected: module)
            let selected = items.filter(\.isSelected)
            XCTAssertEqual(selected.count, 1, "\(module.rawValue) produced \(selected.count) selected chips")
            XCTAssertEqual(selected.first?.module, module)
        }
    }

    func testTitlesAreTheFullDisplayNamesNeverAnAbbreviation() {
        for item in MetricModulePicker.items(selected: .battery) {
            XCTAssertEqual(item.title, item.module.displayName)
            XCTAssertFalse(item.title.isEmpty)
            // "Ne…" is exactly the failure mode being fixed; any renderer
            // that reintroduces an ellipsis into the model is wrong.
            XCTAssertFalse(item.title.contains("…"), "\(item.module.rawValue) carries a truncated title")
        }
    }

    func testEveryItemCarriesASymbol() {
        for item in MetricModulePicker.items(selected: .battery) {
            XCTAssertEqual(item.symbolName, item.module.symbolName)
            XCTAssertFalse(item.symbolName.isEmpty)
        }
    }

    func testNoTwoModulesShareADisplayName() {
        // The property the chip row relies on: full names are unambiguous,
        // so showing them in full is sufficient to disambiguate the picker.
        var seen: [String: MetricModule] = [:]
        for module in MetricModule.allCases {
            if let existing = seen[module.displayName] {
                XCTFail("\(module.rawValue) and \(existing.rawValue) share the name '\(module.displayName)'")
            }
            seen[module.displayName] = module
        }
    }

    func testShortenedNamesCollideWhichIsWhyThePickerMustNotTruncate() {
        // The nine-way segmented control left room for about two characters
        // of "Neural Engine" and "Network" alike. This asserts that the
        // collision is real, so the justification in
        // `PerMetricHistoryBrowser.modulePicker` stays anchored to a fact
        // rather than to a memory of a screenshot.
        //
        // If a future rename happens to remove this particular collision,
        // that is NOT license to reintroduce a truncating picker: the
        // English names are the short ones, and `displayName` is
        // `String(localized:)`, so other languages can collide where these
        // do not. Delete or adjust this test consciously, not reflexively.
        XCTAssertEqual(
            String(MetricModule.ane.displayName.prefix(2)),
            String(MetricModule.network.displayName.prefix(2))
        )
    }

    func testItemsAreIdentifiedByTheirModule() {
        // Drives `ForEach` and `ScrollViewReader.scrollTo` in the chip row;
        // duplicate ids would break both.
        let items = MetricModulePicker.items(selected: .memory)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertEqual(items.first?.id, .battery)
    }
}
