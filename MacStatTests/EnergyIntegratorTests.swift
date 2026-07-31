import XCTest
@testable import MacStatKit

final class EnergyIntegratorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyAndSingleSampleAreZero() {
        XCTAssertEqual(EnergyIntegrator.kilowattHours(samples: []), 0)
        XCTAssertEqual(EnergyIntegrator.kilowattHours(samples: [(timestamp: start, watts: 50)]), 0)
    }

    func testConstantPowerIntegratesExactly() {
        // 36 W held for one hour of 10s ticks = 36 Wh = 0.036 kWh.
        let samples = (0...360).map { tick in
            (timestamp: start.addingTimeInterval(Double(tick) * 10), watts: 36.0)
        }
        XCTAssertEqual(EnergyIntegrator.kilowattHours(samples: samples), 0.036, accuracy: 0.0001)
    }

    func testSleepGapIsCappedNotIntegrated() {
        // Two 20 W readings, 8 hours apart: the gap must contribute at most
        // `maximumGap` worth of energy, not 160 Wh.
        let samples = [
            (timestamp: start, watts: 20.0),
            (timestamp: start.addingTimeInterval(8 * 3600), watts: 20.0),
        ]
        let kWh = EnergyIntegrator.kilowattHours(samples: samples)
        let cappedKWh = 20.0 * EnergyIntegrator.maximumGap / 3_600_000
        XCTAssertEqual(kWh, cappedKWh, accuracy: 1e-9)
    }

    func testNegativeAndNonFiniteWattagesAreDropped() {
        let samples = [
            (timestamp: start, watts: 30.0),
            (timestamp: start.addingTimeInterval(10), watts: -5.0),
            (timestamp: start.addingTimeInterval(20), watts: Double.nan),
            (timestamp: start.addingTimeInterval(30), watts: 30.0),
        ]
        // Only the two clean samples remain, 30s apart at 30 W.
        let expected = 30.0 * 30 / 3_600_000
        XCTAssertEqual(EnergyIntegrator.kilowattHours(samples: samples), expected, accuracy: 1e-9)
    }

    func testUnsortedInputIsSortedInternally() {
        let samples = [
            (timestamp: start.addingTimeInterval(60), watts: 10.0),
            (timestamp: start, watts: 10.0),
        ]
        let expected = 10.0 * 60 / 3_600_000
        XCTAssertEqual(EnergyIntegrator.kilowattHours(samples: samples), expected, accuracy: 1e-9)
    }
}
