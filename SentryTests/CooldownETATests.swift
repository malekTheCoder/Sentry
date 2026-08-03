import XCTest
@testable import SentryKit

final class CooldownETATests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// `count` samples at `interval` spacing, cooling linearly from
    /// `startTemp` at `ratePerSecond` °C/s.
    private func coolingSamples(
        count: Int,
        interval: TimeInterval = 30,
        startTemp: Double,
        ratePerSecond: Double
    ) -> [(timestamp: Date, celsius: Double)] {
        (0..<count).map { index in
            let t = Double(index) * interval
            return (timestamp: start.addingTimeInterval(t), celsius: startTemp - ratePerSecond * t)
        }
    }

    func testNilWithTooFewSamples() {
        let samples = coolingSamples(count: 3, startTemp: 100, ratePerSecond: 0.02)
        XCTAssertNil(SystemAdvisor.cooldownETASeconds(tempSamples: samples))
    }

    func testNilWhenAlreadyUnderThreshold() {
        let samples = coolingSamples(count: 10, startTemp: 94, ratePerSecond: 0.02)
        XCTAssertNil(SystemAdvisor.cooldownETASeconds(tempSamples: samples))
    }

    func testNilWhenHeating() {
        let samples = coolingSamples(count: 10, startTemp: 100, ratePerSecond: -0.02)
        XCTAssertNil(SystemAdvisor.cooldownETASeconds(tempSamples: samples))
    }

    func testNilWhenCoolingWithinNoiseFloor() {
        // 0.001 °C/s is under the 0.005 minimum meaningful rate.
        let samples = coolingSamples(count: 10, startTemp: 100, ratePerSecond: 0.001)
        XCTAssertNil(SystemAdvisor.cooldownETASeconds(tempSamples: samples))
    }

    func testEstimatesLinearCooldown() {
        // 105 °C cooling at 0.02 °C/s over 10 samples 30s apart.
        // Latest = 105 − 0.02·270 = 99.6 °C → (99.6 − 95) / 0.02 = 230s.
        let samples = coolingSamples(count: 10, startTemp: 105, ratePerSecond: 0.02)
        guard let eta = SystemAdvisor.cooldownETASeconds(tempSamples: samples) else {
            return XCTFail("Expected an ETA for a clean linear cooldown")
        }
        XCTAssertEqual(eta, 230, accuracy: 5)
    }

    func testNilWhenETABeyondCap() {
        // Barely above the rate floor but 40 °C over threshold → hours out.
        let samples = coolingSamples(count: 20, startTemp: 135.5, ratePerSecond: 0.006)
        XCTAssertNil(SystemAdvisor.cooldownETASeconds(tempSamples: samples))
    }
}
