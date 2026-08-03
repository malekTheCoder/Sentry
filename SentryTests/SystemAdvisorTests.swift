import XCTest
@testable import SentryKit

final class SystemAdvisorTests: XCTestCase {

    private func snapshot(
        cpu: Double? = nil,
        socTemp: Double? = nil,
        pressure: ThermalStats.PressureLevel = .nominal,
        isThrottling: Bool = false,
        chargePercent: Double? = nil,
        isPluggedIn: Bool = true
    ) -> SystemSnapshot {
        SystemSnapshot(
            deviceID: "test",
            battery: chargePercent.map {
                BatteryStats(chargePercent: $0, isCharging: false, isPluggedIn: isPluggedIn, healthPercent: 100)
            },
            cpu: cpu.map { CPUStats(totalPercent: $0) },
            thermal: ThermalStats(socTemperatureCelsius: socTemp, pressureLevel: pressure, isThrottling: isThrottling)
        )
    }

    // MARK: - SystemAdvisor.recommend

    func testGoWhenNothingIsWrong() {
        let recommendation = SystemAdvisor.recommend(snapshot(cpu: 20, socTemp: 40), lowPowerModeEnabled: false)
        XCTAssertEqual(recommendation.recommendation, "go")
        XCTAssertTrue(recommendation.reasons.isEmpty)
    }

    func testWaitWhenThrottling() {
        let recommendation = SystemAdvisor.recommend(snapshot(isThrottling: true), lowPowerModeEnabled: false)
        XCTAssertEqual(recommendation.recommendation, "wait")
        XCTAssertTrue(recommendation.reasons.contains { $0.contains("throttling") })
    }

    func testWaitWhenThermalPressureSerious() {
        let recommendation = SystemAdvisor.recommend(snapshot(pressure: .serious), lowPowerModeEnabled: false)
        XCTAssertEqual(recommendation.recommendation, "wait")
    }

    func testWaitWhenSoCTempAboveThreshold() {
        let recommendation = SystemAdvisor.recommend(snapshot(socTemp: 96), lowPowerModeEnabled: false)
        XCTAssertEqual(recommendation.recommendation, "wait")
        XCTAssertTrue(recommendation.reasons.contains { $0.contains("96") })
    }

    func testWaitWhenCPUAboveThreshold() {
        let recommendation = SystemAdvisor.recommend(snapshot(cpu: 95), lowPowerModeEnabled: false)
        XCTAssertEqual(recommendation.recommendation, "wait")
    }

    func testWaitWhenLowBatteryOnBattery() {
        let recommendation = SystemAdvisor.recommend(
            snapshot(chargePercent: 15, isPluggedIn: false),
            lowPowerModeEnabled: false
        )
        XCTAssertEqual(recommendation.recommendation, "wait")
    }

    func testGoWhenLowBatteryButPluggedIn() {
        let recommendation = SystemAdvisor.recommend(
            snapshot(chargePercent: 15, isPluggedIn: true),
            lowPowerModeEnabled: false
        )
        XCTAssertEqual(recommendation.recommendation, "go")
    }

    func testWaitWhenLowPowerModeEnabled() {
        let recommendation = SystemAdvisor.recommend(snapshot(), lowPowerModeEnabled: true)
        XCTAssertEqual(recommendation.recommendation, "wait")
    }

    // MARK: - WaitCondition parsing

    func testParsesThermalNormal() {
        XCTAssertEqual(WaitCondition("thermal_normal"), .thermalNormal)
    }

    func testParsesCPUBelow() {
        XCTAssertEqual(WaitCondition("cpu_below:50"), .cpuBelow(50))
    }

    func testParsesBatteryAbove() {
        XCTAssertEqual(WaitCondition("battery_above:30"), .batteryAbove(30))
    }

    func testParsesMemoryBelow() {
        XCTAssertEqual(WaitCondition("memory_below:80"), .memoryBelow(80))
    }

    func testRejectsUnknownCondition() {
        XCTAssertNil(WaitCondition("gpu_below:50"))
    }

    func testRejectsMalformedValue() {
        XCTAssertNil(WaitCondition("cpu_below:notanumber"))
    }

    // MARK: - WaitCondition.isSatisfied

    func testThermalNormalSatisfiedWhenNotThrottling() {
        XCTAssertTrue(WaitCondition.thermalNormal.isSatisfied(by: snapshot(pressure: .nominal)))
        XCTAssertFalse(WaitCondition.thermalNormal.isSatisfied(by: snapshot(pressure: .serious)))
        XCTAssertFalse(WaitCondition.thermalNormal.isSatisfied(by: snapshot(isThrottling: true)))
    }

    func testCPUBelowSatisfaction() {
        XCTAssertTrue(WaitCondition.cpuBelow(50).isSatisfied(by: snapshot(cpu: 30)))
        XCTAssertFalse(WaitCondition.cpuBelow(50).isSatisfied(by: snapshot(cpu: 70)))
    }

    func testBatteryAboveSatisfaction() {
        XCTAssertTrue(WaitCondition.batteryAbove(30).isSatisfied(by: snapshot(chargePercent: 50)))
        XCTAssertFalse(WaitCondition.batteryAbove(30).isSatisfied(by: snapshot(chargePercent: 10)))
    }

    func testMissingDataTreatedAsSatisfied() {
        // No CPU/battery/thermal data at all — a condition Sentry can't
        // measure shouldn't block an agent forever.
        let empty = SystemSnapshot(deviceID: "test")
        XCTAssertTrue(WaitCondition.thermalNormal.isSatisfied(by: empty))
        XCTAssertTrue(WaitCondition.cpuBelow(10).isSatisfied(by: empty))
        XCTAssertTrue(WaitCondition.batteryAbove(90).isSatisfied(by: empty))
        XCTAssertTrue(WaitCondition.memoryBelow(10).isSatisfied(by: empty))
    }
}
