import XCTest
@testable import SentryKit

/// Pins `AgentPreflight`'s verdict policy: every threshold boundary (each
/// tested from both sides), reason subsumption/combination, the
/// `suggestedWaitSeconds` rules, and — the load-bearing one — the invariant
/// that `WaitCondition.ready` (what `wait_until_ready` polls) agrees with
/// `preflight_check`'s verdict on every snapshot, so the two tools can never
/// tell an agent different stories about the same machine.
final class AgentPreflightTests: XCTestCase {

    private func snapshot(
        cpu: Double? = nil,
        socTemp: Double? = nil,
        pressure: ThermalStats.PressureLevel = .nominal,
        isThrottling: Bool = false,
        hasThermal: Bool = true,
        chargePercent: Double? = nil,
        isPluggedIn: Bool = true,
        memoryPressure: MemoryPressureLevel? = nil
    ) -> SystemSnapshot {
        SystemSnapshot(
            deviceID: "test",
            battery: chargePercent.map {
                BatteryStats(chargePercent: $0, isCharging: false, isPluggedIn: isPluggedIn)
            },
            cpu: cpu.map { CPUStats(totalPercent: $0) },
            memory: memoryPressure.map {
                MemoryStats(
                    usedBytes: 8 << 30, appMemoryBytes: 4 << 30, wiredBytes: 2 << 30,
                    compressedBytes: 1 << 30, cachedBytes: 1 << 30, totalBytes: 16 << 30,
                    pressureLevel: $0
                )
            },
            thermal: hasThermal
                ? ThermalStats(socTemperatureCelsius: socTemp, pressureLevel: pressure, isThrottling: isThrottling)
                : nil
        )
    }

    private func assess(
        _ snapshot: SystemSnapshot,
        lowPowerMode: Bool = false,
        otherSessions: Int = 0,
        labels: [String] = [],
        tempSamples: [(timestamp: Date, celsius: Double)] = []
    ) -> AgentPreflight.Assessment {
        AgentPreflight.assess(
            snapshot,
            lowPowerModeEnabled: lowPowerMode,
            otherActiveAgentSessionCount: otherSessions,
            otherActiveAgentLabels: labels,
            recentSoCTemperatureSamples: tempSamples
        )
    }

    private func codes(_ assessment: AgentPreflight.Assessment) -> [AgentPreflight.ReasonCode] {
        assessment.reasons.map(\.code)
    }

    // MARK: - Proceed

    func testProceedWhenNothingIsWrong() {
        let result = assess(snapshot(cpu: 20, socTemp: 40, chargePercent: 80))
        XCTAssertEqual(result.verdict, .proceed)
        XCTAssertTrue(result.reasons.isEmpty)
        XCTAssertNil(result.suggestedWaitSeconds)
    }

    func testProceedOnEmptySnapshot() {
        // No sensors at all — absent data produces no reasons, never a
        // blocked agent (same posture as WaitCondition's missing-data rule).
        let result = assess(SystemSnapshot(deviceID: "test"))
        XCTAssertEqual(result.verdict, .proceed)
    }

    // MARK: - CPU boundary (strict >, at SystemAdvisor.highCPUPercent = 90)

    func testCPUExactlyAtThresholdProceeds() {
        XCTAssertEqual(assess(snapshot(cpu: 90)).verdict, .proceed)
    }

    func testCPUJustAboveThresholdWaits() {
        let result = assess(snapshot(cpu: 90.1))
        XCTAssertEqual(result.verdict, .wait)
        XCTAssertEqual(codes(result), [.cpuSaturated])
    }

    // MARK: - Thermal boundaries

    func testSoCTempExactlyAtThresholdProceeds() {
        XCTAssertEqual(assess(snapshot(socTemp: 95)).verdict, .proceed)
    }

    func testSoCTempJustAboveThresholdWaits() {
        let result = assess(snapshot(socTemp: 95.1))
        XCTAssertEqual(result.verdict, .wait)
        XCTAssertEqual(codes(result), [.thermalElevated])
    }

    func testThrottlingWaits() {
        XCTAssertEqual(assess(snapshot(isThrottling: true)).verdict, .wait)
    }

    func testFairPressureProceeds() {
        XCTAssertEqual(assess(snapshot(pressure: .fair)).verdict, .proceed)
    }

    func testSeriousPressureWaits() {
        XCTAssertEqual(assess(snapshot(pressure: .serious)).verdict, .wait)
    }

    func testCriticalPressureIsDoNotStart() {
        let result = assess(snapshot(pressure: .critical))
        XCTAssertEqual(result.verdict, .doNotStart)
        // Subsumption: critical replaces (never joins) the elevated reason.
        XCTAssertEqual(codes(result), [.thermalCritical])
    }

    // MARK: - Battery boundaries (only on battery; 20% wait / 10% do_not_start)

    func testLowBatteryPluggedInProceeds() {
        XCTAssertEqual(assess(snapshot(chargePercent: 5, isPluggedIn: true)).verdict, .proceed)
    }

    func testBatteryExactlyAtLowThresholdProceeds() {
        XCTAssertEqual(assess(snapshot(chargePercent: 20, isPluggedIn: false)).verdict, .proceed)
    }

    func testBatteryJustBelowLowThresholdWaits() {
        let result = assess(snapshot(chargePercent: 19.9, isPluggedIn: false))
        XCTAssertEqual(result.verdict, .wait)
        XCTAssertEqual(codes(result), [.onBatteryLow])
        // Waiting doesn't recharge a battery — no estimate, ever.
        XCTAssertNil(result.suggestedWaitSeconds)
    }

    func testBatteryJustAboveCriticalThresholdIsStillLow() {
        XCTAssertEqual(codes(assess(snapshot(chargePercent: 10.1, isPluggedIn: false))), [.onBatteryLow])
    }

    func testBatteryAtCriticalThresholdIsDoNotStart() {
        let result = assess(snapshot(chargePercent: 10, isPluggedIn: false))
        XCTAssertEqual(result.verdict, .doNotStart)
        // Subsumption: critical replaces (never joins) the low reason.
        XCTAssertEqual(codes(result), [.onBatteryCritical])
    }

    // MARK: - Memory pressure

    func testMemoryWarningIsCaution() {
        let result = assess(snapshot(memoryPressure: .warning))
        XCTAssertEqual(result.verdict, .caution)
        XCTAssertEqual(codes(result), [.memoryPressure])
    }

    func testMemoryCriticalIsDoNotStart() {
        let result = assess(snapshot(memoryPressure: .critical))
        XCTAssertEqual(result.verdict, .doNotStart)
        XCTAssertEqual(codes(result), [.memoryPressureCritical])
    }

    func testMemoryNormalProceeds() {
        XCTAssertEqual(assess(snapshot(memoryPressure: .normal)).verdict, .proceed)
    }

    // MARK: - Environment reasons

    func testLowPowerModeIsCaution() {
        let result = assess(snapshot(), lowPowerMode: true)
        XCTAssertEqual(result.verdict, .caution)
        XCTAssertEqual(codes(result), [.lowPowerMode])
    }

    func testAnotherAgentActiveIsCaution() {
        let result = assess(snapshot(), otherSessions: 2, labels: ["Claude Code", "Cursor"])
        XCTAssertEqual(result.verdict, .caution)
        XCTAssertEqual(codes(result), [.anotherAgentActive])
        XCTAssertTrue(result.reasons[0].message.contains("Claude Code, Cursor"))
        XCTAssertEqual(result.snapshot.activeAgentSessionCount, 2)
    }

    // MARK: - Combination (verdict = max severity across reasons)

    func testCautionPlusWaitIsWait() {
        let result = assess(snapshot(cpu: 95), lowPowerMode: true)
        XCTAssertEqual(result.verdict, .wait)
        XCTAssertEqual(Set(codes(result)), [.cpuSaturated, .lowPowerMode])
    }

    func testWaitPlusDoNotStartIsDoNotStart() {
        let result = assess(snapshot(cpu: 95, pressure: .critical, chargePercent: 15, isPluggedIn: false))
        XCTAssertEqual(result.verdict, .doNotStart)
        XCTAssertEqual(Set(codes(result)), [.thermalCritical, .cpuSaturated, .onBatteryLow])
    }

    // MARK: - suggestedWaitSeconds

    /// Cooling at 1°C/min from 97°C: crosses back under 95°C in ~120s.
    private var coolingSamples: [(timestamp: Date, celsius: Double)] {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return (0..<4).map { (timestamp: start.addingTimeInterval(Double($0) * 60), celsius: 100 - Double($0)) }
    }

    func testThermalWaitWithCoolingTrendGetsEstimate() {
        let result = assess(snapshot(socTemp: 97), tempSamples: coolingSamples)
        XCTAssertEqual(result.verdict, .wait)
        XCTAssertEqual(result.suggestedWaitSeconds ?? -1, 120, accuracy: 1)
    }

    func testThermalWaitWithoutTrendHasNoEstimate() {
        XCTAssertNil(assess(snapshot(socTemp: 97)).suggestedWaitSeconds)
    }

    func testThermalWaitWithHeatingTrendHasNoEstimate() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let heating = (0..<4).map { (timestamp: start.addingTimeInterval(Double($0) * 60), celsius: 96 + Double($0)) }
        XCTAssertNil(assess(snapshot(socTemp: 99), tempSamples: heating).suggestedWaitSeconds)
    }

    func testNoEstimateUnlessVerdictIsWait() {
        // do_not_start with a cooling trend: still nil — the field's
        // contract is "populated only under a wait verdict."
        XCTAssertNil(assess(snapshot(pressure: .critical), tempSamples: coolingSamples).suggestedWaitSeconds)
        // caution: nil too.
        XCTAssertNil(assess(snapshot(), lowPowerMode: true, tempSamples: coolingSamples).suggestedWaitSeconds)
    }

    func testNonThermalWaitHasNoEstimate() {
        XCTAssertNil(assess(snapshot(cpu: 95), tempSamples: coolingSamples).suggestedWaitSeconds)
    }

    // MARK: - Snapshot echo

    func testSnapshotCarriesTheNumbersBehindTheVerdict() {
        let result = assess(
            snapshot(cpu: 85, socTemp: 60, chargePercent: 42, isPluggedIn: false, memoryPressure: .warning),
            lowPowerMode: true,
            otherSessions: 1
        )
        XCTAssertEqual(result.snapshot.cpuPercent, 85)
        XCTAssertEqual(result.snapshot.socTemperatureCelsius, 60)
        XCTAssertEqual(result.snapshot.batteryChargePercent, 42)
        XCTAssertEqual(result.snapshot.isPluggedIn, false)
        XCTAssertEqual(result.snapshot.memoryPressure, "warning")
        XCTAssertEqual(result.snapshot.thermalPressure, "nominal")
        XCTAssertTrue(result.snapshot.lowPowerModeEnabled)
        XCTAssertEqual(result.snapshot.activeAgentSessionCount, 1)
    }

    // MARK: - Wire stability

    func testVerdictAndReasonCodeRawValuesAreStable() {
        // These cross the wire into agents' prompts and scripts — renames
        // are breaking changes, same rule as MetricID/MCPToolID.
        XCTAssertEqual(AgentPreflight.Verdict.doNotStart.rawValue, "do_not_start")
        XCTAssertEqual(
            AgentPreflight.ReasonCode.allCases.map(\.rawValue),
            [
                "thermal_critical", "thermal_elevated", "cpu_saturated",
                "on_battery_critical", "on_battery_low",
                "memory_pressure_critical", "memory_pressure",
                "low_power_mode", "another_agent_active",
            ]
        )
    }

    // MARK: - wait_until_ready / preflight_check agreement

    func testReadyConditionParses() {
        XCTAssertEqual(WaitCondition("ready"), .ready)
    }

    /// The invariant that makes the two tools one contract: for *any*
    /// snapshot, `wait_until_ready`'s `ready` condition is satisfied exactly
    /// when `preflight_check`'s verdict is below `wait`. Swept over the
    /// cross-product of every boundary this policy has, including both sides
    /// of each threshold.
    func testReadyConditionAgreesWithPreflightVerdictEverywhere() {
        var snapshots: [SystemSnapshot] = [SystemSnapshot(deviceID: "test")]
        for cpu: Double? in [nil, 50, 90, 90.1, 100] {
            for socTemp: Double? in [nil, 80, 95, 95.1] {
                for pressure in ThermalStats.PressureLevel.allCasesForTesting {
                    for throttling in [false, true] {
                        for charge: Double? in [nil, 5, 10, 10.1, 19.9, 20, 80] {
                            for plugged in [false, true] {
                                for memory: MemoryPressureLevel? in [nil, .normal, .warning, .critical] {
                                    snapshots.append(snapshot(
                                        cpu: cpu, socTemp: socTemp, pressure: pressure,
                                        isThrottling: throttling, chargePercent: charge,
                                        isPluggedIn: plugged, memoryPressure: memory
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        for candidate in snapshots {
            let verdict = assess(candidate).verdict
            let ready = WaitCondition.ready.isSatisfied(by: candidate)
            XCTAssertEqual(
                ready,
                verdict == .proceed || verdict == .caution,
                "ready=\(ready) disagrees with verdict=\(verdict.rawValue) for \(candidate)"
            )
        }
    }
}

private extension ThermalStats.PressureLevel {
    /// The enum isn't `CaseIterable` in production (nothing there needs to
    /// enumerate it); the sweep test does, so the list lives here.
    static var allCasesForTesting: [Self] { [.nominal, .fair, .serious, .critical] }
}
