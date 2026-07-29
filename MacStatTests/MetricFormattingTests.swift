import XCTest
@testable import MacStat
@testable import MacStatKit

/// Coverage for the dropdown's nil-handling wrapper around `MetricFormatter`.
///
/// This is a direct regression suite for the "Zero KB" bug: `Optional<UInt64/
/// Int>.map(Double.init)` used as a bare initializer *reference* reinterprets
/// the value's bit pattern instead of numerically converting it, so a real
/// byte count like 48 GB silently rendered as "Zero KB" everywhere in the
/// dropdown. The fix threads `.map { Double($0) }` (a closure, not a bare
/// reference) through `volts`, `amps`, `integer`, and `bytes`; these tests
/// assert the threading is numerically correct, not just non-crashing.
final class MetricFormattingTests: XCTestCase {

    // MARK: - nil always produces the placeholder

    func testValueNilProducesPlaceholder() {
        XCTAssertEqual(MetricFormatting.value(nil, unit: .percent), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.value(nil, unit: .bytes, compact: true), MetricFormatting.placeholder)
    }

    func testValueNaNProducesPlaceholder() {
        // Double.nan is "not a real reading" just like nil for this layer.
        XCTAssertEqual(MetricFormatting.value(.nan, unit: .percent), MetricFormatting.placeholder)
    }

    func testConvenienceShimsNilProducePlaceholder() {
        XCTAssertEqual(MetricFormatting.percent(nil), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.watts(nil), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.celsius(nil), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.volts(nil), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.amps(nil), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.integer(nil), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.bytes(nil), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.bytesPerSecond(nil), MetricFormatting.placeholder)
    }

    func testMinutesRemainingNilOrNegativeProducesPlaceholder() {
        XCTAssertEqual(MetricFormatting.minutesRemaining(nil), MetricFormatting.placeholder)
        // IOKit's "still calculating" sentinel.
        XCTAssertEqual(MetricFormatting.minutesRemaining(-1), MetricFormatting.placeholder)
    }

    func testUptimeNilLikeInputsProducePlaceholder() {
        XCTAssertEqual(MetricFormatting.uptime(.nan), MetricFormatting.placeholder)
        XCTAssertEqual(MetricFormatting.uptime(-5), MetricFormatting.placeholder)
    }

    // MARK: - non-nil values thread correctly through to MetricFormatter

    func testValueThreadsThroughToDetailedByDefault() {
        XCTAssertEqual(MetricFormatting.value(72.34, unit: .percent), MetricFormatter.detailed(72.34, unit: .percent))
    }

    func testValueThreadsThroughToCompactWhenRequested() {
        XCTAssertEqual(
            MetricFormatting.value(72.34, unit: .percent, compact: true),
            MetricFormatter.compact(72.34, unit: .percent)
        )
    }

    func testPercentDecimalsZeroUsesCompact() {
        XCTAssertEqual(MetricFormatting.percent(72.6, decimals: 0), MetricFormatter.compact(72.6, unit: .percent))
    }

    func testPercentDecimalsNonzeroUsesDetailed() {
        XCTAssertEqual(MetricFormatting.percent(72.34, decimals: 1), MetricFormatter.detailed(72.34, unit: .percent))
    }

    func testUptimePrefixesUp() {
        XCTAssertEqual(MetricFormatting.uptime(3661), "up " + MetricFormatter.uptime(3661))
    }

    // MARK: - Regression: Optional<UInt64/Int>.map(Double.init) bit-pattern bug

    func testBytesLargeUInt64DoesNotProduceZeroKB() {
        // 51,539,607,552 bytes ≈ 48 GB. Under the old `.map(Double.init)`
        // bare-reference bug this silently became garbage/near-zero and
        // rendered as "Zero KB". It must now render as a real GB-scale value.
        let result = MetricFormatting.bytes(UInt64(51_539_607_552))
        XCTAssertFalse(result.lowercased().contains("zero"), "regression: got \(result)")
        XCTAssertTrue(result.contains("GB"), "expected GB-scale string, got \(result)")
    }

    func testBytesMatchesDirectMetricFormatterCall() {
        let raw: UInt64 = 51_539_607_552
        XCTAssertEqual(MetricFormatting.bytes(raw), MetricFormatter.compact(Double(raw), unit: .bytes))
    }

    func testBytesSmallUInt64() {
        let result = MetricFormatting.bytes(UInt64(1024))
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, MetricFormatting.placeholder)
    }

    func testBytesZeroIsNotPlaceholder() {
        // Zero is a real (if uninteresting) reading, distinct from nil.
        XCTAssertNotEqual(MetricFormatting.bytes(UInt64(0)), MetricFormatting.placeholder)
    }

    func testVoltsThreadsIntCorrectly() {
        // 11800 mV -> 11.80V. Under the bit-pattern bug this would not
        // reliably equal Double(11800).
        XCTAssertEqual(MetricFormatting.volts(11800), MetricFormatter.compact(11800, unit: .millivolts))
        XCTAssertTrue(MetricFormatting.volts(11800).contains("11.80"))
    }

    func testAmpsThreadsIntCorrectly() {
        XCTAssertEqual(MetricFormatting.amps(2500), MetricFormatter.compact(2500, unit: .milliamps))
        XCTAssertTrue(MetricFormatting.amps(2500).contains("2.50"))
    }

    func testIntegerThreadsLargeIntCorrectly() {
        // A count large enough that a bit-reinterpretation bug would produce
        // a wildly different number rather than a plausible off-by-rounding.
        let large = 2_000_000_000
        XCTAssertEqual(MetricFormatting.integer(large), MetricFormatter.compact(Double(large), unit: .count))
        XCTAssertEqual(MetricFormatting.integer(large), "2000000000")
    }

    func testIntegerNegativeValue() {
        XCTAssertEqual(MetricFormatting.integer(-42), MetricFormatter.compact(-42, unit: .count))
    }

    func testBytesPerSecondThreadsThrough() {
        XCTAssertEqual(
            MetricFormatting.bytesPerSecond(8_400_000),
            MetricFormatter.compact(8_400_000, unit: .bytesPerSecond)
        )
    }
}
