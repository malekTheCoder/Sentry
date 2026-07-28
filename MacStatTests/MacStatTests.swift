import XCTest
@testable import MacStatKit
@testable import SystemMetricsKit

final class MacStatTests: XCTestCase {
    func testSystemSnapshotConstructs() {
        let snapshot = SystemSnapshot(deviceID: "test-device")
        XCTAssertEqual(snapshot.deviceID, "test-device")
        XCTAssertNil(snapshot.battery)
    }

    func testDeltaTrackerFirstCallReturnsNil() {
        let tracker = DeltaTracker()
        XCTAssertNil(tracker.rate(for: 100, at: Date()))
    }

    func testDeltaTrackerComputesRate() {
        let tracker = DeltaTracker()
        let t0 = Date()
        _ = tracker.rate(for: 100, at: t0)
        let rate = tracker.rate(for: 300, at: t0.addingTimeInterval(2))
        XCTAssertEqual(rate ?? -1, 100, accuracy: 0.001)
    }

    func testDeltaTrackerHandlesWraparound() {
        let tracker = DeltaTracker()
        let t0 = Date()
        _ = tracker.rate(for: UInt64(UInt32.max) - 10, at: t0)
        // Counter wrapped past UInt32.max and is now at 5.
        let rate = tracker.rate(for: 5, at: t0.addingTimeInterval(1))
        XCTAssertEqual(rate ?? -1, 15, accuracy: 0.001)
    }
}
