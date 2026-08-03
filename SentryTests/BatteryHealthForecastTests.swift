import XCTest
@testable import SentryKit

final class BatteryHealthForecastTests: XCTestCase {

    private let day: TimeInterval = 24 * 3600

    /// `count` daily samples ending at `now`, declining linearly from
    /// `start` health by `perDay` percent per day.
    private func decliningSamples(
        count: Int,
        start: Double,
        perDay: Double,
        now: Date
    ) -> [(timestamp: Date, health: Double)] {
        (0..<count).map { index in
            (
                timestamp: now.addingTimeInterval(-Double(count - 1 - index) * day),
                health: start - Double(index) * perDay
            )
        }
    }

    func testInsufficientDataWithTooFewSamples() {
        let now = Date()
        let samples = decliningSamples(count: 3, start: 95, perDay: 0.1, now: now)
        XCTAssertEqual(BatteryHealthForecast.forecast(samples: samples, now: now), .insufficientData)
    }

    func testInsufficientDataWithTooShortSpan() {
        let now = Date()
        // Ten samples but all within one day — span far under the two-week floor.
        let samples = (0..<10).map { index in
            (timestamp: now.addingTimeInterval(Double(index) * 3600), health: 95.0 - Double(index) * 0.01)
        }
        XCTAssertEqual(BatteryHealthForecast.forecast(samples: samples, now: now), .insufficientData)
    }

    func testStableWhenFlat() {
        let now = Date()
        let samples = decliningSamples(count: 30, start: 92, perDay: 0, now: now)
        XCTAssertEqual(BatteryHealthForecast.forecast(samples: samples, now: now), .stable)
    }

    func testStableWhenImproving() {
        let now = Date()
        // Calibration bumps do happen — an "improving" battery must not
        // produce a crossing date.
        let samples = decliningSamples(count: 30, start: 90, perDay: -0.05, now: now)
        XCTAssertEqual(BatteryHealthForecast.forecast(samples: samples, now: now), .stable)
    }

    func testAlreadyBelowThreshold() {
        let now = Date()
        let samples = decliningSamples(count: 30, start: 82, perDay: 0.2, now: now)
        XCTAssertEqual(BatteryHealthForecast.forecast(samples: samples, now: now), .alreadyBelow)
    }

    func testProjectsCrossingDateAtLinearRate() {
        let now = Date()
        // 30 days ending today, 95% → declining 0.1%/day. Latest ≈ 92.1%,
        // so ~121 more days to reach 80%.
        let samples = decliningSamples(count: 30, start: 95, perDay: 0.1, now: now)
        guard case .crosses(let date, let percentPerMonth) =
            BatteryHealthForecast.forecast(samples: samples, now: now) else {
            return XCTFail("Expected a crossing forecast")
        }
        let daysOut = date.timeIntervalSince(now) / day
        XCTAssertEqual(daysOut, 121, accuracy: 3)
        XCTAssertEqual(percentPerMonth, 0.1 * 30.44, accuracy: 0.02)
    }

    func testFarFutureCrossingCollapsesToStable() {
        let now = Date()
        // 0.01%/day → threshold is ~3+ years past the 5-year horizon… make
        // it unambiguous: 0.005%/day ≈ 16 years out.
        let samples = decliningSamples(count: 60, start: 95, perDay: 0.005, now: now)
        XCTAssertEqual(BatteryHealthForecast.forecast(samples: samples, now: now), .stable)
    }

    func testNonFiniteSamplesAreDropped() {
        let now = Date()
        var samples = decliningSamples(count: 30, start: 95, perDay: 0.1, now: now)
        samples.append((timestamp: now.addingTimeInterval(60), health: .nan))
        guard case .crosses = BatteryHealthForecast.forecast(samples: samples, now: now) else {
            return XCTFail("NaN sample should be ignored, not poison the fit")
        }
    }
}
