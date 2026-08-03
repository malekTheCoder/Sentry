import XCTest
@testable import Sentry
import SentryKit

final class AnomalyDetectorTests: XCTestCase {

    func testFlagsMetricAboveThreshold() {
        let anomalies = AnomalyDetector.detect(
            currentValues: [.cpuTotalPercent: 80],
            baselines: [.cpuTotalPercent: .init(averageValue: 50, sampleDayCount: 7)]
        )
        XCTAssertEqual(anomalies.count, 1)
        XCTAssertEqual(anomalies.first?.metricID, .cpuTotalPercent)
        XCTAssertEqual(anomalies.first?.percentDeviation ?? 0, 60, accuracy: 0.01)
    }

    func testDoesNotFlagWithinThreshold() {
        let anomalies = AnomalyDetector.detect(
            currentValues: [.cpuTotalPercent: 55],
            baselines: [.cpuTotalPercent: .init(averageValue: 50, sampleDayCount: 7)]
        )
        XCTAssertTrue(anomalies.isEmpty, "10% deviation is well under the 25% threshold")
    }

    func testFlagsBelowBaselineWithNegativeDeviation() {
        let anomalies = AnomalyDetector.detect(
            currentValues: [.thermalSocTempC: 30],
            baselines: [.thermalSocTempC: .init(averageValue: 50, sampleDayCount: 10)]
        )
        XCTAssertEqual(anomalies.first?.percentDeviation ?? 0, -40, accuracy: 0.01)
    }

    func testIgnoresMetricWithInsufficientBaselineHistory() {
        let anomalies = AnomalyDetector.detect(
            currentValues: [.cpuTotalPercent: 90],
            baselines: [.cpuTotalPercent: .init(averageValue: 10, sampleDayCount: 1)]
        )
        XCTAssertTrue(anomalies.isEmpty, "1 day of history is below minimumBaselineDays")
    }

    func testIgnoresMetricWithZeroBaseline() {
        let anomalies = AnomalyDetector.detect(
            currentValues: [.cpuTotalPercent: 50],
            baselines: [.cpuTotalPercent: .init(averageValue: 0, sampleDayCount: 10)]
        )
        XCTAssertTrue(anomalies.isEmpty, "a zero baseline can't produce a meaningful percent deviation")
    }

    func testIgnoresMetricWithNoCurrentValue() {
        let anomalies = AnomalyDetector.detect(
            currentValues: [:],
            baselines: [.cpuTotalPercent: .init(averageValue: 50, sampleDayCount: 10)]
        )
        XCTAssertTrue(anomalies.isEmpty)
    }

    func testSortsByDeviationMagnitudeDescending() {
        let anomalies = AnomalyDetector.detect(
            currentValues: [.cpuTotalPercent: 60, .thermalSocTempC: 100],
            baselines: [
                .cpuTotalPercent: .init(averageValue: 40, sampleDayCount: 7), // +50%
                .thermalSocTempC: .init(averageValue: 40, sampleDayCount: 7)  // +150%
            ]
        )
        XCTAssertEqual(anomalies.map(\.metricID), [.thermalSocTempC, .cpuTotalPercent])
    }

    func testIgnoresNonCandidateMetric() {
        // .diskReadBytesPerSec is deliberately not a candidate — bursty
        // throughput metrics would fire constantly on ordinary use.
        let anomalies = AnomalyDetector.detect(
            currentValues: [.diskReadBytesPerSec: 1_000_000_000],
            baselines: [.diskReadBytesPerSec: .init(averageValue: 1_000, sampleDayCount: 10)]
        )
        XCTAssertTrue(anomalies.isEmpty)
    }
}
