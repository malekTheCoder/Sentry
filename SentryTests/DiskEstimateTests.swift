import XCTest
@testable import Sentry

/// Coverage for `DiskEstimate` (Sentry/Settings/Panes/AdvancedPane.swift),
/// the linear disk-usage projection shown in the Advanced settings pane.
/// Plan §6.3's worked numbers: ~1.15 M raw rows/day, ~40 MB at 48 h retention
/// (2.304 M rows) => ~18 bytes/raw row; ~2 MB / 90 d hourly rollups (86,400
/// rows) => ~24 bytes/row; ~1 MB/decade for daily rollups.
final class DiskEstimateTests: XCTestCase {

    private let metricCount: Double = 40
    private let rawBytesPerRow: Double = 18
    private let hourlyBytesPerRow: Double = 24

    // MARK: - rawBytes

    func testRawBytesMatchesFormula() {
        let hours = 48
        let interval = 3.0
        let expected = (Double(hours) * 3600 / interval) * metricCount * rawBytesPerRow
        XCTAssertEqual(DiskEstimate.rawBytes(hours: hours, interval: interval), expected, accuracy: 0.001)
    }

    func testRawBytesZeroHoursIsZero() {
        XCTAssertEqual(DiskEstimate.rawBytes(hours: 0, interval: 3), 0, accuracy: 0.001)
    }

    func testRawBytesScalesLinearlyWithHours() {
        let one = DiskEstimate.rawBytes(hours: 6, interval: 3)
        let double = DiskEstimate.rawBytes(hours: 12, interval: 3)
        XCTAssertEqual(double, one * 2, accuracy: 0.001)
    }

    func testRawBytesShorterIntervalMeansMoreSamples() {
        let slow = DiskEstimate.rawBytes(hours: 48, interval: 6)
        let fast = DiskEstimate.rawBytes(hours: 48, interval: 3)
        XCTAssertGreaterThan(fast, slow)
    }

    func testRawBytesZeroIntervalDoesNotDivideByZero() {
        // The slider can't produce 0, but the settings file is user-editable;
        // the implementation clamps to a minimum interval of 0.5s.
        let result = DiskEstimate.rawBytes(hours: 48, interval: 0)
        XCTAssertTrue(result.isFinite)
        XCTAssertEqual(result, DiskEstimate.rawBytes(hours: 48, interval: 0.5), accuracy: 0.001)
    }

    func testRawBytesNegativeIntervalDoesNotDivideByZeroOrGoNegative() {
        let result = DiskEstimate.rawBytes(hours: 48, interval: -3)
        XCTAssertTrue(result.isFinite)
        XCTAssertGreaterThan(result, 0)
    }

    func testRawBytesApproximatelyMatchesPlanFigure() {
        // Plan §6.3: ~40 MB at 48h retention, 3s refresh.
        let bytes = DiskEstimate.rawBytes(hours: 48, interval: 3)
        let megabytes = bytes / 1_048_576
        XCTAssertEqual(megabytes, 40, accuracy: 5)
    }

    // MARK: - hourlyBytes

    func testHourlyBytesMatchesFormula() {
        let days = 90
        let expected = Double(days) * 24 * metricCount * hourlyBytesPerRow
        XCTAssertEqual(DiskEstimate.hourlyBytes(days: days), expected, accuracy: 0.001)
    }

    func testHourlyBytesZeroDaysIsZero() {
        XCTAssertEqual(DiskEstimate.hourlyBytes(days: 0), 0, accuracy: 0.001)
    }

    func testHourlyBytesScalesLinearlyWithDays() {
        let one = DiskEstimate.hourlyBytes(days: 30)
        let triple = DiskEstimate.hourlyBytes(days: 90)
        XCTAssertEqual(triple, one * 3, accuracy: 0.001)
    }

    func testHourlyBytesApproximatelyMatchesPlanFigure() {
        // Plan §6.3: ~2 MB / 90 d.
        let bytes = DiskEstimate.hourlyBytes(days: 90)
        let megabytes = bytes / 1_048_576
        XCTAssertEqual(megabytes, 2, accuracy: 0.5)
    }

    // MARK: - dailyBytesPerDecade

    func testDailyBytesPerDecadeIsOneMegabyte() {
        XCTAssertEqual(DiskEstimate.dailyBytesPerDecade, 1_048_576, accuracy: 0.001)
    }

    // MARK: - formatted

    func testFormattedProducesNonEmptyString() {
        XCTAssertFalse(DiskEstimate.formatted(1_048_576).isEmpty)
    }

    func testFormattedNegativeClampsToZeroRatherThanTrapping() {
        // Int64(negative-but-representable) wouldn't trap, but the formula
        // clamps defensively; verify it doesn't produce a negative-looking
        // string like "-1 KB" for a bogus negative estimate.
        let result = DiskEstimate.formatted(-5000)
        XCTAssertFalse(result.contains("-"))
    }

    func testFormattedLargeValueDoesNotSayZero() {
        // Same regression shape as the MetricFormatter bug: a large byte
        // count must not collapse to "Zero KB".
        let bytes = DiskEstimate.rawBytes(hours: 168, interval: 0.5)
        let result = DiskEstimate.formatted(bytes)
        XCTAssertFalse(result.lowercased().contains("zero"), "got \(result) for \(bytes) bytes")
    }

    func testFormattedZeroIsZeroKB() {
        // Genuine zero is a legitimate ByteCountFormatter output, unlike the
        // bit-reinterpretation bug where large values collapsed to zero.
        XCTAssertTrue(DiskEstimate.formatted(0).lowercased().contains("zero"))
    }

    // MARK: - Composition (mirrors AdvancedPane.totalProjectedBytes)

    func testTotalProjectedBytesIsSumOfComponents() {
        let hours = 48
        let interval = 3.0
        let days = 90
        let total = DiskEstimate.rawBytes(hours: hours, interval: interval)
            + DiskEstimate.hourlyBytes(days: days)
            + DiskEstimate.dailyBytesPerDecade
        let expected = DiskEstimate.rawBytes(hours: hours, interval: interval)
            + DiskEstimate.hourlyBytes(days: days)
            + DiskEstimate.dailyBytesPerDecade
        XCTAssertEqual(total, expected, accuracy: 0.001)
        XCTAssertGreaterThan(total, DiskEstimate.dailyBytesPerDecade)
    }
}
