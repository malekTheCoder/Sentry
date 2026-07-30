import XCTest
import MacStatKit

/// `SyntheticDailyHealth.series` is pure and deterministic (seeded from
/// `deviceID`, `endingAt` is a parameter rather than `Date()`), so these
/// pin exact invariants — day count, ordering, monotonic cycle count,
/// plausible bounds, reproducibility — rather than just checking it doesn't
/// crash. See that type's doc comment for why this math lives in
/// `MacStatKit` instead of next to its only real call site,
/// `MockDataSource.dailyHealthHistory` in `MacStatMobile`.
final class SyntheticDailyHealthTests: XCTestCase {

    private let endDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testReturnsRequestedDayCount() {
        let series = SyntheticDailyHealth.series(deviceID: "device-1", dayCount: 10, endingAt: endDate)
        XCTAssertEqual(series.count, 10)
    }

    func testZeroOrNegativeDayCountReturnsEmpty() {
        XCTAssertTrue(SyntheticDailyHealth.series(deviceID: "device-1", dayCount: 0, endingAt: endDate).isEmpty)
        XCTAssertTrue(SyntheticDailyHealth.series(deviceID: "device-1", dayCount: -5, endingAt: endDate).isEmpty)
    }

    func testDaysAreAscendingAndExactlyOneDayApart() {
        let series = SyntheticDailyHealth.series(deviceID: "device-1", dayCount: 8, endingAt: endDate)
        for i in 1..<series.count {
            let delta = series[i].day.timeIntervalSince(series[i - 1].day)
            XCTAssertEqual(delta, 86400, accuracy: 0.001)
        }
    }

    func testLastRecordLandsOnEndingAtsCalendarDay() {
        let calendar = Calendar(identifier: .gregorian)
        let series = SyntheticDailyHealth.series(deviceID: "device-1", dayCount: 5, endingAt: endDate)
        XCTAssertEqual(series.last?.day, calendar.startOfDay(for: endDate))
    }

    func testHealthPercentStaysWithinPlausibleBounds() {
        // A long series exercises the degradation curve's floor clamp.
        let series = SyntheticDailyHealth.series(deviceID: "device-1", dayCount: 400, endingAt: endDate)
        for record in series {
            XCTAssertGreaterThanOrEqual(record.healthPercent, 70)
            XCTAssertLessThanOrEqual(record.healthPercent, 100)
        }
    }

    func testCycleCountIsNonDecreasingOldestToNewest() {
        let series = SyntheticDailyHealth.series(deviceID: "device-1", dayCount: 30, endingAt: endDate)
        for i in 1..<series.count {
            XCTAssertGreaterThanOrEqual(series[i].cycleCount, series[i - 1].cycleCount)
        }
    }

    func testFullChargeCapacityTracksHealthPercentProportionally() {
        let designCapacity = 6800
        let series = SyntheticDailyHealth.series(
            deviceID: "device-1", dayCount: 6, endingAt: endDate, designCapacityMAh: designCapacity
        )
        for record in series {
            let expected = Int((Double(designCapacity) * record.healthPercent / 100).rounded())
            XCTAssertEqual(record.fullChargeCapacity, expected)
        }
    }

    func testMinChargeNeverExceedsMaxCharge() {
        let series = SyntheticDailyHealth.series(deviceID: "device-1", dayCount: 60, endingAt: endDate)
        for record in series {
            XCTAssertLessThanOrEqual(record.minCharge, record.maxCharge)
        }
    }

    func testSameDeviceIDIsDeterministicAcrossCalls() {
        let a = SyntheticDailyHealth.series(deviceID: "same-device", dayCount: 20, endingAt: endDate)
        let b = SyntheticDailyHealth.series(deviceID: "same-device", dayCount: 20, endingAt: endDate)
        XCTAssertEqual(a, b)
    }

    func testDifferentDeviceIDsProduceDifferentSeries() {
        let a = SyntheticDailyHealth.series(deviceID: "device-a", dayCount: 20, endingAt: endDate)
        let b = SyntheticDailyHealth.series(deviceID: "device-b", dayCount: 20, endingAt: endDate)
        XCTAssertNotEqual(a, b)
    }

    func testEveryRecordCarriesTheRequestedDeviceID() {
        let series = SyntheticDailyHealth.series(deviceID: "my-mac", dayCount: 12, endingAt: endDate)
        XCTAssertTrue(series.allSatisfy { $0.deviceID == "my-mac" })
    }
}
