import XCTest
@testable import MacStatKit

/// Coverage for the shared formatter (plan §3.2 P5). This is the area that
/// produced the "Zero KB" regression: `Optional<UInt64/Int>.map(Double.init)`
/// used as a bare initializer reference silently reinterpreted bit patterns
/// instead of converting numbers, so byte/count fields rendered as zero
/// everywhere. That bug is fixed (cb05467); these tests exist so a
/// regression of the same shape fails a build instead of requiring manual
/// empirical testing to catch.
final class MetricFormatterTests: XCTestCase {

    // MARK: - compact: normal values per unit

    func testCompactPercent() {
        XCTAssertEqual(MetricFormatter.compact(72, unit: .percent), "72%")
        XCTAssertEqual(MetricFormatter.compact(72.6, unit: .percent), "73%")
    }

    func testCompactWattsSwitchesPrecisionAtTen() {
        XCTAssertEqual(MetricFormatter.compact(4.567, unit: .watts), "4.6W")
        XCTAssertEqual(MetricFormatter.compact(45.8, unit: .watts), "46W")
        XCTAssertEqual(MetricFormatter.compact(9.99, unit: .watts), "10.0W")
        XCTAssertEqual(MetricFormatter.compact(10.0, unit: .watts), "10W")
    }

    func testCompactCelsius() {
        XCTAssertEqual(MetricFormatter.compact(58.4, unit: .celsius), "58°")
    }

    func testCompactMegahertzSwitchesToGHz() {
        XCTAssertEqual(MetricFormatter.compact(800, unit: .megahertz), "800MHz")
        XCTAssertEqual(MetricFormatter.compact(3200, unit: .megahertz), "3.2GHz")
        XCTAssertEqual(MetricFormatter.compact(1000, unit: .megahertz), "1.0GHz")
    }

    func testCompactBytesRegressionLargeValue() {
        // The exact class of bug that was just fixed: a large byte count
        // must format as a sensible GB string, not "Zero KB" or garbage.
        let result = MetricFormatter.compact(51_539_607_552, unit: .bytes)
        XCTAssertTrue(result.contains("GB"), "expected a GB-scale string, got \(result)")
        XCTAssertFalse(result.lowercased().contains("zero"), "regression: got \(result)")
    }

    func testCompactBytesSmallValues() {
        let result = MetricFormatter.compact(512, unit: .bytes)
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.lowercased().contains("zero"))
    }

    func testCompactBytesZero() {
        // Zero bytes is a legitimate reading (not "unavailable"), and must
        // not be confused with the NaN/garbage-bit-pattern failure mode.
        let result = MetricFormatter.compact(0, unit: .bytes)
        XCTAssertFalse(result.isEmpty)
    }

    func testCompactBytesPerSecondHasSlashSuffix() {
        let result = MetricFormatter.compact(8_400_000, unit: .bytesPerSecond)
        XCTAssertTrue(result.hasSuffix("/s"), "got \(result)")
    }

    func testCompactOperationsPerSecondAndCount() {
        XCTAssertEqual(MetricFormatter.compact(1234, unit: .operationsPerSecond), "1234 IOPS")
        XCTAssertEqual(MetricFormatter.compact(42, unit: .count), "42")
    }

    func testCompactMinutesFormatsHoursAndMinutes() {
        XCTAssertEqual(MetricFormatter.compact(45, unit: .minutes), "45m")
        XCTAssertEqual(MetricFormatter.compact(125, unit: .minutes), "2h 5m")
        XCTAssertEqual(MetricFormatter.compact(0, unit: .minutes), "0m")
    }

    func testCompactMinutesNegativeIsUnavailable() {
        // IOKit reports -1 for "still calculating"; must not render as "-1m".
        XCTAssertEqual(MetricFormatter.compact(-1, unit: .minutes), MetricFormatter.unavailable)
    }

    func testCompactSecondsDelegatesToUptime() {
        XCTAssertEqual(MetricFormatter.compact(3661, unit: .seconds), MetricFormatter.uptime(3661))
    }

    func testCompactDecimal() {
        XCTAssertEqual(MetricFormatter.compact(1.5, unit: .decimal), "1.50")
    }

    func testCompactThermalLevel() {
        XCTAssertEqual(MetricFormatter.compact(0, unit: .thermalLevel), "Nominal")
        XCTAssertEqual(MetricFormatter.compact(1, unit: .thermalLevel), "Fair")
        XCTAssertEqual(MetricFormatter.compact(2, unit: .thermalLevel), "Serious")
        XCTAssertEqual(MetricFormatter.compact(3, unit: .thermalLevel), "Critical")
        XCTAssertEqual(MetricFormatter.compact(99, unit: .thermalLevel), "Critical")
        XCTAssertEqual(MetricFormatter.compact(-5, unit: .thermalLevel), "Nominal")
    }

    func testCompactMillivoltsConvertsToVolts() {
        XCTAssertEqual(MetricFormatter.compact(11800, unit: .millivolts), "11.80V")
    }

    func testCompactMilliampsConvertsToAmps() {
        XCTAssertEqual(MetricFormatter.compact(2500, unit: .milliamps), "2.50A")
    }

    func testCompactDecibelMilliwatts() {
        XCTAssertEqual(MetricFormatter.compact(-55, unit: .decibelMilliwatts), "-55 dBm")
    }

    func testCompactMegabitsPerSecond() {
        XCTAssertEqual(MetricFormatter.compact(866, unit: .megabitsPerSecond), "866 Mbps")
    }

    func testCompactBoolean() {
        XCTAssertEqual(MetricFormatter.compact(1, unit: .boolean), "Yes")
        XCTAssertEqual(MetricFormatter.compact(0, unit: .boolean), "No")
        XCTAssertEqual(MetricFormatter.compact(-1, unit: .boolean), "No")
    }

    // MARK: - NaN / Infinity: must not trap, must return the placeholder

    func testCompactNaNReturnsUnavailableForEveryUnit() {
        for unit in allUnits() {
            XCTAssertEqual(
                MetricFormatter.compact(.nan, unit: unit),
                MetricFormatter.unavailable,
                "unit \(unit) did not guard NaN"
            )
        }
    }

    func testCompactPositiveInfinityReturnsUnavailableForEveryUnit() {
        for unit in allUnits() {
            XCTAssertEqual(
                MetricFormatter.compact(.infinity, unit: unit),
                MetricFormatter.unavailable,
                "unit \(unit) did not guard +infinity"
            )
        }
    }

    func testCompactNegativeInfinityReturnsUnavailableForEveryUnit() {
        for unit in allUnits() {
            XCTAssertEqual(
                MetricFormatter.compact(-.infinity, unit: unit),
                MetricFormatter.unavailable,
                "unit \(unit) did not guard -infinity"
            )
        }
    }

    func testUptimeGuardsNonFiniteValues() {
        XCTAssertEqual(MetricFormatter.uptime(.nan), MetricFormatter.unavailable)
        XCTAssertEqual(MetricFormatter.uptime(.infinity), MetricFormatter.unavailable)
        XCTAssertEqual(MetricFormatter.uptime(-.infinity), MetricFormatter.unavailable)
    }

    func testDetailedGuardsNonFiniteValues() {
        XCTAssertEqual(MetricFormatter.detailed(.nan, unit: .watts), MetricFormatter.unavailable)
        XCTAssertEqual(MetricFormatter.detailed(.infinity, unit: .percent), MetricFormatter.unavailable)
    }

    // MARK: - Very large values (the bit-reinterpretation bug class)

    func testCompactBytesVeryLargeValueDoesNotTrapOrGarbage() {
        // Larger than Int64.max as a raw double magnitude class, to exercise
        // clampToInt64's saturation rather than a runtime trap.
        let huge = Double(UInt64.max) * 4
        let result = MetricFormatter.compact(huge, unit: .bytes)
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.lowercased().contains("zero"))
    }

    func testCompactMinutesVeryLargeValueDoesNotTrap() {
        let huge = Double.greatestFiniteMagnitude
        let result = MetricFormatter.compact(huge, unit: .minutes)
        XCTAssertFalse(result.isEmpty)
    }

    func testUptimeVeryLargeValueDoesNotTrap() {
        let huge = Double.greatestFiniteMagnitude
        let result = MetricFormatter.uptime(huge)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Very small non-zero values

    func testCompactWattsVerySmallValue() {
        XCTAssertEqual(MetricFormatter.compact(0.001, unit: .watts), "0.0W")
    }

    func testCompactBytesVerySmallValue() {
        let result = MetricFormatter.compact(1, unit: .bytes)
        XCTAssertFalse(result.isEmpty)
    }

    func testCompactPercentVerySmallValueRoundsToZero() {
        XCTAssertEqual(MetricFormatter.compact(0.001, unit: .percent), "0%")
    }

    // MARK: - Negative values where applicable

    func testCompactWattsNegative() {
        // Watts can legitimately be negative (net power flow); must not trap.
        XCTAssertEqual(MetricFormatter.compact(-4.5, unit: .watts), "-4.5W")
    }

    func testCompactCelsiusNegative() {
        XCTAssertEqual(MetricFormatter.compact(-10, unit: .celsius), "-10°")
    }

    func testCompactDecibelMilliwattsNegative() {
        XCTAssertEqual(MetricFormatter.compact(-70, unit: .decibelMilliwatts), "-70 dBm")
    }

    // MARK: - includeUnit parameter, especially transformed units

    func testIncludeUnitFalseOmitsSuffixEvenWhenTransformed() {
        XCTAssertEqual(MetricFormatter.compact(11800, unit: .millivolts, includeUnit: false), "11.80")
        XCTAssertEqual(MetricFormatter.compact(2500, unit: .milliamps, includeUnit: false), "2.50")
        XCTAssertEqual(MetricFormatter.compact(3200, unit: .megahertz, includeUnit: false), "3.2")
        XCTAssertEqual(MetricFormatter.compact(72, unit: .percent, includeUnit: false), "72")
    }

    func testIncludeUnitTrueMatchesConcatenationOfNumberAndSuffix() {
        for unit in allUnits() {
            let value = 42.0
            let full = MetricFormatter.compact(value, unit: unit, includeUnit: true)
            let bare = MetricFormatter.compact(value, unit: unit, includeUnit: false)
            XCTAssertTrue(full.hasPrefix(bare), "unit \(unit): '\(full)' does not start with '\(bare)'")
        }
    }

    // MARK: - detailed

    func testDetailedPercent() {
        XCTAssertEqual(MetricFormatter.detailed(72.34, unit: .percent), "72.3%")
    }

    func testDetailedWatts() {
        XCTAssertEqual(MetricFormatter.detailed(4.5, unit: .watts), "4.50 W")
    }

    func testDetailedCelsius() {
        XCTAssertEqual(MetricFormatter.detailed(58.44, unit: .celsius), "58.4 °C")
    }

    func testDetailedFallsBackToCompactForOtherUnits() {
        XCTAssertEqual(MetricFormatter.detailed(1234, unit: .count), MetricFormatter.compact(1234, unit: .count))
    }

    // MARK: - uptime

    func testUptimeDays() {
        XCTAssertEqual(MetricFormatter.uptime(3 * 86400 + 4 * 3600), "3d 4h")
    }

    func testUptimeHours() {
        XCTAssertEqual(MetricFormatter.uptime(5 * 3600 + 12 * 60), "5h 12m")
    }

    func testUptimeMinutesOnly() {
        XCTAssertEqual(MetricFormatter.uptime(42 * 60), "42m")
    }

    func testUptimeZero() {
        XCTAssertEqual(MetricFormatter.uptime(0), "0m")
    }

    func testUptimeNegativeClampsToZero() {
        XCTAssertEqual(MetricFormatter.uptime(-100), "0m")
    }

    // MARK: - Helpers

    private func allUnits() -> [MetricUnit] {
        [
            .percent, .watts, .celsius, .megahertz, .bytes, .bytesPerSecond,
            .operationsPerSecond, .minutes, .seconds, .millivolts, .milliamps,
            .decibelMilliwatts, .megabitsPerSecond, .boolean, .count, .decimal,
            .thermalLevel
        ]
    }
}
