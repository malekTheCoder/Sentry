import XCTest
@testable import SentryKit

/// The pure fan-control arithmetic (plan §12: curve interpolation, RPM
/// clamping, safety-ceiling enforcement).
///
/// All of it is testable today, on any Mac including a fanless one, years
/// before there is a write path to exercise it against — which is the whole
/// reason `FanControl.swift` keeps this logic in value types with no IOKit
/// anywhere near it. These assertions are true about the *code* regardless
/// of whether anything ever calls it against hardware, the same claim
/// `SyncServiceTests` makes about a CloudKit container that doesn't exist.
final class FanControlModelTests: XCTestCase {

    private let limits = FanHardwareLimits(minRPM: 1200, maxRPM: 6241)

    // MARK: - Hardware limits

    func testLimitsRejectInvertedRange() {
        // Plan §5.3's first rule. Note it's *detected*, not silently
        // repaired by swapping — a silent swap would turn "this reading is
        // wrong" into "this reading is fine".
        XCTAssertFalse(FanHardwareLimits(minRPM: 6000, maxRPM: 1200).isValid)
        XCTAssertTrue(FanHardwareLimits(minRPM: 1200, maxRPM: 6000).isValid)
    }

    func testLimitsRejectNonFiniteAndNegative() {
        XCTAssertFalse(FanHardwareLimits(minRPM: -1, maxRPM: 6000).isValid)
        XCTAssertFalse(FanHardwareLimits(minRPM: 1200, maxRPM: .nan).isValid)
        XCTAssertFalse(FanHardwareLimits(minRPM: .infinity, maxRPM: .infinity).isValid)
    }

    func testClampConfinesToHardwareRange() {
        XCTAssertEqual(limits.clamp(0), 1200)
        XCTAssertEqual(limits.clamp(99_999), 6241)
        XCTAssertEqual(limits.clamp(3000), 3000)
    }

    func testClampLeavesValueAloneWhenLimitsAreInvalid() {
        // Clamping to a range that makes no sense would be worse than not
        // clamping: the caller has `isValid` to check first.
        let broken = FanHardwareLimits(minRPM: 6000, maxRPM: 1200)
        XCTAssertEqual(broken.clamp(3000), 3000)
    }

    func testFractionMapsAcrossTheMeasuredRange() {
        XCTAssertEqual(limits.rpm(atFraction: 0), 1200)
        XCTAssertEqual(limits.rpm(atFraction: 1), 6241)
        XCTAssertEqual(limits.rpm(atFraction: 0.5), (1200 + 6241) / 2, accuracy: 0.0001)
        // Out-of-range fractions are bounded, not extrapolated.
        XCTAssertEqual(limits.rpm(atFraction: -3), 1200)
        XCTAssertEqual(limits.rpm(atFraction: 7), 6241)
    }

    // MARK: - Curve interpolation

    private let curve = FanCurve(points: [
        FanCurvePoint(celsius: 50, rpm: 1200),
        FanCurvePoint(celsius: 70, rpm: 2000),
        FanCurvePoint(celsius: 85, rpm: 4000),
        FanCurvePoint(celsius: 95, rpm: 6000),
    ])

    func testCurveInterpolatesLinearlyBetweenPoints() {
        XCTAssertEqual(curve.targetRPM(atCelsius: 60) ?? -1, 1600, accuracy: 0.0001)
        XCTAssertEqual(curve.targetRPM(atCelsius: 77.5) ?? -1, 3000, accuracy: 0.0001)
        XCTAssertEqual(curve.targetRPM(atCelsius: 90) ?? -1, 5000, accuracy: 0.0001)
    }

    func testCurveReturnsExactValuesAtBreakpoints() {
        XCTAssertEqual(curve.targetRPM(atCelsius: 70) ?? -1, 2000, accuracy: 0.0001)
        XCTAssertEqual(curve.targetRPM(atCelsius: 85) ?? -1, 4000, accuracy: 0.0001)
    }

    func testCurveHoldsFlatOutsideItsEnds() {
        // Extrapolating past the ends would let a curve request an RPM the
        // user never drew — most expensive precisely at the hot end.
        XCTAssertEqual(curve.targetRPM(atCelsius: 10) ?? -1, 1200, accuracy: 0.0001)
        XCTAssertEqual(curve.targetRPM(atCelsius: 130) ?? -1, 6000, accuracy: 0.0001)
    }

    func testEmptyCurveProducesNoTargetRatherThanZero() {
        // A curve with no points expresses no opinion. Inventing one (0?
        // minimum? maximum?) would be the fabricated reading this codebase
        // forbids.
        XCTAssertNil(FanCurve(points: []).targetRPM(atCelsius: 70))
    }

    func testCurveSortsUnorderedPointsSoInterpolationIsMeaningful() {
        let unordered = FanCurve(points: [
            FanCurvePoint(celsius: 95, rpm: 6000),
            FanCurvePoint(celsius: 50, rpm: 1200),
            FanCurvePoint(celsius: 70, rpm: 2000),
        ])
        XCTAssertEqual(unordered.points.map(\.celsius), [50, 70, 95])
        XCTAssertEqual(unordered.targetRPM(atCelsius: 60) ?? -1, 1600, accuracy: 0.0001)
    }

    func testNonFiniteTemperatureProducesNoTarget() {
        XCTAssertNil(curve.targetRPM(atCelsius: .nan))
    }

    // MARK: - Curve validation (plan §5.3)

    func testValidCurveHasNoIssues() {
        XCTAssertTrue(curve.issues(against: FanHardwareLimits(minRPM: 1200, maxRPM: 6000)).isEmpty)
    }

    func testFallingRPMIsReportedAsAnIssue() {
        let backwards = FanCurve(points: [
            FanCurvePoint(celsius: 50, rpm: 4000),
            FanCurvePoint(celsius: 90, rpm: 2000),
        ])
        XCTAssertEqual(
            backwards.issues(),
            [.rpmFallsAsTemperatureRises(fromCelsius: 50, toCelsius: 90)]
        )
    }

    func testDuplicateTemperatureIsReported() {
        let duplicated = FanCurve(points: [
            FanCurvePoint(celsius: 70, rpm: 2000),
            FanCurvePoint(celsius: 70, rpm: 2500),
        ])
        XCTAssertTrue(duplicated.issues().contains(.duplicateTemperature(celsius: 70)))
    }

    func testOutOfRangePointIsReportedOnlyWhenLimitsAreKnown() {
        let tooFast = FanCurve(points: [FanCurvePoint(celsius: 95, rpm: 9000)])
        // With no limits there is nothing honest to range-check against —
        // checking against a hardcoded ceiling would invent a limit.
        XCTAssertTrue(tooFast.issues(against: nil).isEmpty)
        XCTAssertEqual(
            tooFast.issues(against: limits),
            [.rpmOutsideHardwareLimits(celsius: 95, rpm: 9000, limits: limits)]
        )
    }

    func testEmptyCurveIsItsOwnIssue() {
        XCTAssertEqual(FanCurve(points: []).issues(), [.empty])
    }

    func testClampedIsExplicitAndNeverAutomatic() {
        let tooFast = FanCurve(points: [
            FanCurvePoint(celsius: 50, rpm: 0),
            FanCurvePoint(celsius: 95, rpm: 9000),
        ])
        // The unclamped curve keeps the user's values...
        XCTAssertEqual(tooFast.points.map(\.rpm), [0, 9000])
        // ...until something explicitly asks for the clamped copy.
        XCTAssertEqual(tooFast.clamped(to: limits).points.map(\.rpm), [1200, 6241])
    }

    // MARK: - Presets

    func testPresetsAreExpressedAgainstTheFansOwnRange() {
        // The spike measured fan 0 and fan 1 of the same MacBook Pro
        // topping out 462 rpm apart — no absolute preset could be right for
        // both.
        let fan0 = FanHardwareLimits(minRPM: 1200, maxRPM: 5779)
        let fan1 = FanHardwareLimits(minRPM: 1200, maxRPM: 6241)
        XCTAssertEqual(FanControlPreset.balanced.curve(for: fan0).points.last?.rpm, 5779)
        XCTAssertEqual(FanControlPreset.balanced.curve(for: fan1).points.last?.rpm, 6241)
    }

    func testEveryPresetProducesAValidCurveWithinHardwareLimits() {
        for preset in FanControlPreset.allCases {
            let produced = preset.curve(for: limits)
            XCTAssertEqual(produced.points.count, FanControlPreset.breakpointsCelsius.count, "\(preset)")
            XCTAssertTrue(produced.issues(against: limits).isEmpty, "\(preset) produced \(produced.issues(against: limits))")
        }
    }

    // MARK: - Resolver: auto

    func testAutoDefersToTheSystemRatherThanRequestingAnything() {
        // `.deferToSystem` is deliberately distinct from `.unavailable`:
        // handing the fan to the firmware is a decision, not a failure.
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .auto),
            sensorCelsius: 80,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertEqual(resolution.outcome, .deferToSystem)
        XCTAssertNil(resolution.targetRPM)
    }

    // MARK: - Resolver: manual + clamping

    func testManualWithoutAChosenSpeedIsUnavailableNotZero() {
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .manual, manualTargetRPM: nil),
            sensorCelsius: 60,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertNil(resolution.targetRPM)
        if case .unavailable = resolution.outcome {} else {
            XCTFail("a fixed-speed mode with no chosen speed must not resolve to a number")
        }
    }

    func testManualClampsToHardwareAndSaysItDid() {
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .manual, manualTargetRPM: 9000),
            sensorCelsius: 60,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertEqual(resolution.targetRPM, 6241)
        XCTAssertTrue(resolution.wasClamped)
    }

    func testManualDoesNotClaimAClampThatDidNotHappen() {
        let inRange = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .manual, manualTargetRPM: 3000),
            sensorCelsius: 60,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertFalse(inRange.wasClamped)

        // No readable limits means nothing was clamped, so `wasClamped`
        // must stay false — a small lie is still a lie.
        let noLimits = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .manual, manualTargetRPM: 9000),
            sensorCelsius: 60,
            pressure: .nominal,
            limits: nil
        )
        XCTAssertEqual(noLimits.targetRPM, 9000)
        XCTAssertFalse(noLimits.wasClamped)
    }

    // MARK: - Resolver: sensor curve

    func testSensorCurveFollowsTheCurve() {
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .sensorCurve, curve: curve),
            sensorCelsius: 77.5,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertEqual(resolution.targetRPM ?? -1, 3000, accuracy: 0.0001)
    }

    func testSensorCurveWithNoReadingIsUnavailableAndNeverAssumesCold() {
        // Guessing a temperature to feed a fan curve is the most dangerous
        // fabrication this feature could make.
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .sensorCurve, curve: curve),
            sensorCelsius: nil,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertNil(resolution.targetRPM)
        if case .unavailable = resolution.outcome {} else {
            XCTFail("a curve with no sensor reading must not resolve to a number")
        }
    }

    func testSensorCurveResultIsClampedToHardware() {
        let hotCurve = FanCurve(points: [FanCurvePoint(celsius: 50, rpm: 20_000)])
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .sensorCurve, curve: hotCurve),
            sensorCelsius: 60,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertEqual(resolution.targetRPM, 6241)
        XCTAssertTrue(resolution.wasClamped)
    }

    // MARK: - Resolver: safety ceiling (plan §6.4)

    func testHybridJumpsToMaximumAboveTheSafetyCeiling() {
        let policy = FanControlPolicy(mode: .hybrid, curve: curve, safetyCeilingCelsius: 95)
        let resolution = FanControlResolver.resolve(
            policy: policy,
            sensorCelsius: 96,
            pressure: .nominal,
            limits: limits
        )
        XCTAssertEqual(resolution.targetRPM, 6241)
        XCTAssertTrue(resolution.safetyCeilingEngaged)
    }

    func testHybridJumpsToMaximumOnSeriousThermalPressureEvenWithoutASensor() {
        // `ProcessInfo.thermalState` is available on every Mac even where no
        // temperature sensor is, so this path must fire with `nil` celsius.
        let policy = FanControlPolicy(mode: .hybrid, curve: curve)
        for pressure: ThermalStats.PressureLevel in [.serious, .critical] {
            let resolution = FanControlResolver.resolve(
                policy: policy,
                sensorCelsius: nil,
                pressure: pressure,
                limits: limits
            )
            XCTAssertEqual(resolution.targetRPM, 6241, "\(pressure)")
            XCTAssertTrue(resolution.safetyCeilingEngaged, "\(pressure)")
        }
    }

    func testSensorCurveModeIgnoresTheCeilingEntirely() {
        // Only `.hybrid` carries the emergency override; plain `.sensorCurve`
        // is documented as following the curve and nothing else.
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .sensorCurve, curve: curve, safetyCeilingCelsius: 95),
            sensorCelsius: 96,
            pressure: .critical,
            limits: limits
        )
        XCTAssertFalse(resolution.safetyCeilingEngaged)
        XCTAssertEqual(resolution.targetRPM ?? -1, 6000, accuracy: 0.0001)
    }

    func testCeilingWithUnreadableLimitsRefusesRatherThanInventingAMaximum() {
        let resolution = FanControlResolver.resolve(
            policy: FanControlPolicy(mode: .hybrid, curve: curve),
            sensorCelsius: 99,
            pressure: .nominal,
            limits: nil
        )
        XCTAssertTrue(resolution.safetyCeilingEngaged)
        XCTAssertNil(resolution.targetRPM)
        if case .unavailable = resolution.outcome {} else {
            XCTFail("with no readable maximum there is no maximum to request")
        }
    }

    // MARK: - Resolver: hysteresis (plan §5.3 "must not flap")

    func testHysteresisHoldsThePreviousTargetForSmallSensorMoves() {
        let policy = FanControlPolicy(mode: .sensorCurve, curve: curve, hysteresisCelsius: 3)
        let resolution = FanControlResolver.resolve(
            policy: policy,
            sensorCelsius: 78,
            pressure: .nominal,
            limits: limits,
            memory: FanResolutionMemory(celsius: 77.5, rpm: 3000)
        )
        XCTAssertEqual(resolution.targetRPM, 3000)
        XCTAssertTrue(resolution.heldByHysteresis)
    }

    func testHysteresisYieldsOnceTheSensorMovesFarEnough() {
        let policy = FanControlPolicy(mode: .sensorCurve, curve: curve, hysteresisCelsius: 3)
        let resolution = FanControlResolver.resolve(
            policy: policy,
            sensorCelsius: 85,
            pressure: .nominal,
            limits: limits,
            memory: FanResolutionMemory(celsius: 77.5, rpm: 3000)
        )
        XCTAssertEqual(resolution.targetRPM ?? -1, 4000, accuracy: 0.0001)
        XCTAssertFalse(resolution.heldByHysteresis)
    }

    func testZeroHysteresisNeverHolds() {
        let policy = FanControlPolicy(mode: .sensorCurve, curve: curve, hysteresisCelsius: 0)
        let resolution = FanControlResolver.resolve(
            policy: policy,
            sensorCelsius: 77.6,
            pressure: .nominal,
            limits: limits,
            memory: FanResolutionMemory(celsius: 77.5, rpm: 3000)
        )
        XCTAssertFalse(resolution.heldByHysteresis)
    }

    func testHysteresisNeverOverridesTheSafetyCeiling() {
        // The ceiling is checked before hysteresis on purpose: a held
        // target must not keep the fans slow through a thermal emergency.
        let policy = FanControlPolicy(mode: .hybrid, curve: curve, hysteresisCelsius: 20, safetyCeilingCelsius: 95)
        let resolution = FanControlResolver.resolve(
            policy: policy,
            sensorCelsius: 96,
            pressure: .nominal,
            limits: limits,
            memory: FanResolutionMemory(celsius: 95.5, rpm: 1200)
        )
        XCTAssertEqual(resolution.targetRPM, 6241)
        XCTAssertTrue(resolution.safetyCeilingEngaged)
        XCTAssertFalse(resolution.heldByHysteresis)
    }

    // MARK: - Mode metadata

    func testOnlyAutoIsReachableWithoutAPrivilegedWrite() {
        XCTAssertFalse(FanControlMode.auto.requiresPrivilegedWrite)
        for mode in FanControlMode.allCases where mode != .auto {
            XCTAssertTrue(mode.requiresPrivilegedWrite, "\(mode)")
        }
    }
}
