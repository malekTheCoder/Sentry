import XCTest
@testable import SentryKit

/// Coverage for `WidgetSnapshot`/`WidgetBatteryHistory` (`SentryKit/Sync/WidgetSnapshot.swift`)
/// — the App-Group-shared cache `SentryWidget` reads. `WidgetSnapshotStore`
/// itself (the `UserDefaults(suiteName:)` read/write) isn't covered here: it
/// needs a real App Group container/entitlement to do anything observable,
/// which isn't available in a unit-test host — see that type's own doc
/// comment on why every one of its failure modes already degrades to
/// `nil`/no-op rather than throwing, which is the behavior that actually
/// matters and doesn't need a live container to verify by inspection.
final class WidgetSnapshotTests: XCTestCase {

    private func sampleSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            deviceName: "Malek's MacBook Pro",
            lastSeen: Date(timeIntervalSince1970: 1_000_000),
            writtenAt: Date(timeIntervalSince1970: 1_000_010),
            sourceIsDemoData: true,
            batteryPercent: 78,
            isCharging: true,
            isPluggedIn: true,
            chargingWatts: 45,
            cpuPercent: 12,
            memoryUsedFraction: 0.55,
            sleepAssertion: .inactive,
            batteryHistory: [
                WidgetBatteryHistoryPoint(date: Date(timeIntervalSince1970: 999_000), percent: 70),
                WidgetBatteryHistoryPoint(date: Date(timeIntervalSince1970: 999_900), percent: 74),
            ]
        )
    }

    // MARK: - Codable round-trip (what actually crosses the App Group boundary)

    func testRoundTripsThroughJSONExactly() throws {
        let original = sampleSnapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripsActiveSleepAssertion() throws {
        var snapshot = sampleSnapshot()
        let expiresAt = Date(timeIntervalSince1970: 1_003_600)
        snapshot.sleepAssertion = .active(mode: .systemOnly, expiresAt: expiresAt, reason: "Demo")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.sleepAssertion, snapshot.sleepAssertion)
    }

    func testRoundTripsNilOptionalFields() throws {
        var snapshot = sampleSnapshot()
        snapshot.chargingWatts = nil
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(decoded.chargingWatts)
    }

    // MARK: - WidgetBatteryHistory: append + cap

    func testAppendingUnderCapKeepsAllPoints() {
        let existing = [
            WidgetBatteryHistoryPoint(date: Date(timeIntervalSince1970: 0), percent: 50),
        ]
        let newPoint = WidgetBatteryHistoryPoint(date: Date(timeIntervalSince1970: 60), percent: 51)
        let result = WidgetBatteryHistory.appending(newPoint, to: existing, cap: 5)
        XCTAssertEqual(result, existing + [newPoint])
    }

    func testAppendingAtCapDropsOldestPoint() {
        let existing = (0..<5).map {
            WidgetBatteryHistoryPoint(date: Date(timeIntervalSince1970: Double($0 * 60)), percent: Double($0))
        }
        let newPoint = WidgetBatteryHistoryPoint(date: Date(timeIntervalSince1970: 600), percent: 99)
        let result = WidgetBatteryHistory.appending(newPoint, to: existing, cap: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first, existing[1]) // oldest (index 0) dropped
        XCTAssertEqual(result.last, newPoint)
    }

    func testAppendingRepeatedlyNeverExceedsCap() {
        var history: [WidgetBatteryHistoryPoint] = []
        for i in 0..<200 {
            let point = WidgetBatteryHistoryPoint(date: Date(timeIntervalSince1970: Double(i)), percent: Double(i % 100))
            history = WidgetBatteryHistory.appending(point, to: history, cap: 10)
            XCTAssertLessThanOrEqual(history.count, 10)
        }
        XCTAssertEqual(history.count, 10)
        // The final point appended should always be last.
        XCTAssertEqual(history.last?.date, Date(timeIntervalSince1970: 199))
    }

    func testDefaultCapMatchesDocumentedValue() {
        XCTAssertEqual(WidgetBatteryHistory.cap, 48)
    }
}
