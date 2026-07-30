import XCTest
@testable import MacStat
@testable import MacStatKit

/// Coverage for the pure display logic in `SyncPane`
/// (MacStat/Settings/Panes/SyncPane.swift). `SyncPane` itself never holds a
/// `SyncService` instance — it reads only `SyncService`'s `static` cadence
/// functions (see that file's doc comment for why) — so everything worth
/// pinning down here is the arithmetic that turns those numbers into the
/// sentences on screen, with no view hierarchy required.
@MainActor
final class SyncPaneFormattingTests: XCTestCase {

    // MARK: - intervalLabel

    func testIntervalLabelPluralizesSeconds() {
        XCTAssertEqual(SyncPane.intervalLabel(30), "Every 30 seconds")
        XCTAssertEqual(SyncPane.intervalLabel(1), "Every 1 second")
    }

    func testIntervalLabelPluralizesMinutes() {
        XCTAssertEqual(SyncPane.intervalLabel(300), "Every 5 minutes")
        XCTAssertEqual(SyncPane.intervalLabel(60), "Every 1 minute")
        XCTAssertEqual(SyncPane.intervalLabel(600), "Every 10 minutes")
    }

    func testIntervalLabelTreatsNonPositiveAsImmediate() {
        // Mirrors `AlertsPane.humanDuration`'s handling of a hand-edited
        // negative interval: treat it as "now" rather than printing a
        // negative or divide-by-zero-flavored string.
        XCTAssertEqual(SyncPane.intervalLabel(0), "Immediately")
        XCTAssertEqual(SyncPane.intervalLabel(-5), "Immediately")
    }

    // MARK: - cadenceRows

    func testCadenceRowsMatchSyncServicesOwnCadenceTable() {
        let rows = SyncPane.cadenceRows()
        XCTAssertEqual(rows.count, 4)

        // Every interval row is derived from `SyncService.effectiveInterval`
        // directly, not a duplicated literal — if the plan §7.4 defaults ever
        // change, this test (and the pane) move with them automatically.
        let acActive = SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: true)
        let acIdle = SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: false)
        let battery = SyncService.effectiveInterval(onBattery: true, iPhoneRecentlyActive: false)

        XCTAssertEqual(rows[0].interval, SyncPane.intervalLabel(acActive))
        XCTAssertEqual(rows[1].interval, SyncPane.intervalLabel(acIdle))
        XCTAssertEqual(rows[2].interval, SyncPane.intervalLabel(battery))
        XCTAssertEqual(rows[3].interval, "Immediately")
    }

    func testCadenceRowConditionsAreAllDistinct() {
        // `CadenceRow.id` is derived from `condition` (see its doc comment) —
        // a collision here would silently merge two rows in a `List`.
        let conditions = SyncPane.cadenceRows().map(\.condition)
        XCTAssertEqual(Set(conditions).count, conditions.count)
    }
}
