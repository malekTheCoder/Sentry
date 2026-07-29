import XCTest
@testable import MacStatKit

/// `shortLabel` used to fall through to `rawValue` for 29 of 52 cases,
/// leaking dotted machine identifiers (e.g. "thermal.pressure_level") into
/// user-facing UI — visible with zero user action via the shipped "Thermal
/// throttling" alert rule in the Alerts settings pane. These tests pin down
/// the contract so a future case addition can't silently reintroduce the
/// fallback, and so two metrics can never collide on the same label in a
/// settings picker.
final class MetricIDLabelTests: XCTestCase {

    /// The menu bar is the tightest horizontal budget in the app (see
    /// `BarModuleRenderer` / `StatusItemView` truncation logic). This is a
    /// generous ceiling, not a design target — existing labels top out
    /// around 13 characters.
    private let maxLabelLength = 16

    func testEveryCaseHasANonEmptyLabel() {
        for metric in MetricID.allCases {
            XCTAssertFalse(
                metric.shortLabel.isEmpty,
                "\(metric.rawValue) has an empty shortLabel"
            )
        }
    }

    func testNoLabelFallsThroughToRawValue() {
        for metric in MetricID.allCases {
            XCTAssertNotEqual(
                metric.shortLabel, metric.rawValue,
                "\(metric.rawValue) still falls through to its raw dotted identifier"
            )
        }
    }

    func testNoTwoMetricsShareALabel() {
        var seen: [String: MetricID] = [:]
        for metric in MetricID.allCases {
            if let existing = seen[metric.shortLabel] {
                XCTFail(
                    "\(metric.rawValue) and \(existing.rawValue) both render as \"\(metric.shortLabel)\" — ambiguous in a settings picker"
                )
            }
            seen[metric.shortLabel] = metric
        }
    }

    func testLabelsStayWithinMenuBarLengthBudget() {
        for metric in MetricID.allCases {
            XCTAssertLessThanOrEqual(
                metric.shortLabel.count, maxLabelLength,
                "\(metric.rawValue)'s shortLabel \"\(metric.shortLabel)\" exceeds the menu bar length budget of \(maxLabelLength)"
            )
        }
    }

    func testAllCasesAreCovered() {
        // MetricID.allCases comes from CaseIterable; this just guards
        // against the enum growing without the other assertions here
        // running against the new case (they iterate allCases already,
        // so this is mostly a sanity check that allCases isn't empty).
        XCTAssertEqual(MetricID.allCases.count, 52)
    }
}
