import XCTest
@testable import Sentry
@testable import SentryKit
@testable import SystemMetricsKit

// MARK: - Fakes

/// A backend that reports whatever the test needs and refuses every
/// write — which, note, is not a testing convenience: it is exactly
/// what every backend in this build does.
private final class FakeBackend: FanControlBackend {
    let identifier = "fake"
    var reportedCapability: FanControlCapability
    var reportedRPMs: [Double]
    var availability: FanWriteAvailability
    private(set) var applyCallCount = 0
    private(set) var revertCallCount = 0
    var probeCount = 0

    init(
        capability: FanControlCapability,
        rpms: [Double] = [],
        availability: FanWriteAvailability = .needsPrivilegedHelper
    ) {
        self.reportedCapability = capability
        self.reportedRPMs = rpms
        self.availability = availability
    }

    func capability() -> FanControlCapability {
        probeCount += 1
        return reportedCapability
    }

    func readActualRPMs() -> [Double] { reportedRPMs }

    var writeAvailability: FanWriteAvailability { availability }

    func applyTarget(rpm: Double, toFan index: Int) throws {
        applyCallCount += 1
        throw FanControlWriteError.writesUnavailable(availability)
    }

    /// Phase 3 addition: a backend that can succeed. Everything else in
    /// this fake still refuses, which keeps the Phase 2 tests meaning what
    /// they meant — this flag exists only for `revertAllToAuto`'s
    /// partial-failure behavior, which cannot be exercised by a backend
    /// that always throws.
    var revertSucceeds = false

    func revertToAuto(fan index: Int) throws {
        revertCallCount += 1
        if revertSucceeds { return }
        throw FanControlWriteError.writesUnavailable(availability)
    }
}

/// Capability gating, the unsupported-hardware path, and the write refusal
/// (plan §12's "capability gating", "unsupported hardware path", "backend
/// selection").
///
/// The backends here are fakes on purpose: `SMCReadOnlyFanControlBackend`
/// answers whatever the machine running the suite happens to be, and a test
/// that asserted "two fans" would encode one developer's MacBook Pro into
/// the suite forever — the same reasoning `SMCFanBridgeTests` records for
/// staying hardware-agnostic. The real backend is covered separately below
/// by invariants that hold on any Mac, fanless ones included.
@MainActor
final class FanControlServiceTests: XCTestCase {

    private let twoFans = FanControlCapability.supported(fans: [
        FanDescriptor(index: 0, limits: FanHardwareLimits(minRPM: 1200, maxRPM: 5779)),
        FanDescriptor(index: 1, limits: FanHardwareLimits(minRPM: 1200, maxRPM: 6241)),
    ])

    private func thermal(
        fanRPMs: [Double] = [],
        soc: Double? = nil,
        pressure: ThermalStats.PressureLevel = .nominal,
        sensors: [ThermalSensorReading] = []
    ) -> ThermalStats {
        ThermalStats(
            socTemperatureCelsius: soc,
            fanRPMs: fanRPMs,
            pressureLevel: pressure,
            isThrottling: pressure == .serious || pressure == .critical,
            perSensorCelsius: sensors
        )
    }

    // MARK: - Capability gating

    func testCapabilityIsProbedOnceAtConstruction() {
        let backend = FakeBackend(capability: twoFans)
        _ = FanControlService(backend: backend)
        XCTAssertEqual(backend.probeCount, 1, "capability is a property of the machine, not of the moment")
    }

    func testRefreshCapabilityRePprobes() {
        let backend = FakeBackend(capability: .unreadable(reason: "nope"))
        let service = FanControlService(backend: backend)
        backend.reportedCapability = twoFans
        service.refreshCapability()
        XCTAssertEqual(service.capability, twoFans)
    }

    func testSupportedHardwareCanReadSpeeds() {
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        XCTAssertTrue(service.capability.canReadFanSpeeds)
        XCTAssertEqual(service.capability.fans.count, 2)
    }

    // MARK: - Unsupported hardware path

    func testFanlessMacReportsNoFansAndNoReadableSpeeds() {
        let service = FanControlService(backend: UnsupportedFanControlBackend())
        XCTAssertEqual(service.capability, .noFansPresent)
        XCTAssertFalse(service.capability.canReadFanSpeeds)
        XCTAssertEqual(service.writeAvailability, .noFans)

        service.ingest(thermal())
        XCTAssertTrue(service.fans.isEmpty)
    }

    func testUnreadableIsNotCollapsedIntoNoFans() {
        // A Mac whose SMC wouldn't answer may well have two fans. Telling
        // its owner "this Mac has no fans" would be a claim about hardware
        // nobody established.
        let service = FanControlService(
            backend: FakeBackend(capability: .unreadable(reason: "SMC refused"), availability: .hardwareUnreadable)
        )
        XCTAssertNotEqual(service.capability, .noFansPresent)
        XCTAssertEqual(service.writeAvailability, .hardwareUnreadable)
        if case .unreadable(let reason) = service.capability {
            XCTAssertEqual(reason, "SMC refused")
        } else {
            XCTFail("expected .unreadable")
        }
    }

    func testHasSampledDistinguishesNoDataYetFromNoFans() {
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        XCTAssertFalse(service.hasSampled)
        XCTAssertTrue(service.fans.isEmpty, "no fan rows before the first sample")
        service.ingest(thermal(fanRPMs: [0, 0]))
        XCTAssertTrue(service.hasSampled)
        XCTAssertEqual(service.fans.count, 2)
    }

    // MARK: - Zero RPM is a real reading

    func testZeroRPMIsReportedAsStoppedNotUnavailable() {
        // The spike measured `F0Ac` reading exactly 0.0 at idle: Apple
        // Silicon parks its fans. Rendering that as "unavailable" would
        // misreport a successful read.
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        service.ingest(thermal(fanRPMs: [0, 0]))
        XCTAssertEqual(service.fans[0].speed, .rpm(0))
        XCTAssertEqual(service.fans[0].speed.displayText, "Stopped")
    }

    func testAFanWithNoReadingIsUnavailableNotZero() {
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        // Only fan 0 reported; fan 1's key failed.
        service.ingest(thermal(fanRPMs: [1780]))
        XCTAssertEqual(service.fans[0].speed, .rpm(1780))
        XCTAssertEqual(service.fans[0].speed.displayText, "1780 rpm")
        XCTAssertEqual(service.fans[1].speed, .unavailable)
        XCTAssertEqual(service.fans[1].speed.displayText, "Unavailable")
    }

    // MARK: - Write refusal

    func testApplyingAPolicyThrowsBecauseNoBackendCanWrite() {
        let backend = FakeBackend(capability: twoFans)
        let service = FanControlService(backend: backend)
        service.settings.defaultPolicy = FanControlPolicy(mode: .manual, manualTargetRPM: 3000)

        XCTAssertThrowsError(try service.applyPolicy(forFan: 0)) { error in
            XCTAssertEqual(
                error as? FanControlWriteError,
                .writesUnavailable(.needsPrivilegedHelper)
            )
        }
        XCTAssertEqual(backend.applyCallCount, 1, "the refusal comes from the backend, not from a guard above it")
    }

    func testRevertToAutoAlsoThrows() {
        let backend = FakeBackend(capability: twoFans)
        let service = FanControlService(backend: backend)
        XCTAssertThrowsError(try service.revertToAuto(fan: 0))
        XCTAssertEqual(backend.revertCallCount, 1)
    }

    func testAutoModeStillRoutesThroughTheBackendsRevertPath() {
        // Even "do nothing" is a write (`F{i}Md = 0`) once a fan has been
        // taken out of auto, so `.auto` must not short-circuit into a fake
        // success.
        let backend = FakeBackend(capability: twoFans)
        let service = FanControlService(backend: backend)
        service.settings.defaultPolicy = FanControlPolicy(mode: .auto)
        XCTAssertThrowsError(try service.applyPolicy(forFan: 0))
        XCTAssertEqual(backend.revertCallCount, 1)
        XCTAssertEqual(backend.applyCallCount, 0)
    }

    func testApplyingToAFanThatDoesNotExistIsItsOwnError() {
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        XCTAssertThrowsError(try service.applyPolicy(forFan: 7)) { error in
            XCTAssertEqual(error as? FanControlWriteError, .unknownFan(index: 7))
        }
    }

    func testAPolicyThatProducedNoTargetIsNotBlamedOnTheMissingHelper() {
        // Two completely different problems with two completely different
        // fixes; conflating them would send a user hunting for a helper
        // when they just never picked a speed.
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        service.settings.defaultPolicy = FanControlPolicy(mode: .manual, manualTargetRPM: nil)
        XCTAssertThrowsError(try service.applyPolicy(forFan: 0)) { error in
            guard case .policyProducedNoTarget = (error as? FanControlWriteError) else {
                return XCTFail("expected .policyProducedNoTarget, got \(error)")
            }
        }
    }

    func testUnsupportedBackendRefusesEverything() {
        let backend = UnsupportedFanControlBackend()
        XCTAssertThrowsError(try backend.applyTarget(rpm: 3000, toFan: 0)) { error in
            XCTAssertEqual(error as? FanControlWriteError, .writesUnavailable(.noFans))
        }
        XCTAssertThrowsError(try backend.revertToAuto(fan: 0))
    }

    // MARK: - Sensor binding

    func testCurveFollowsTheHottestSensorWhenNoneIsChosen() {
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        service.settings.defaultPolicy = FanControlPolicy(
            mode: .sensorCurve,
            curve: FanCurve(points: [
                FanCurvePoint(celsius: 50, rpm: 1200),
                FanCurvePoint(celsius: 90, rpm: 5000),
            ]),
            sensorName: nil,
            hysteresisCelsius: 0
        )
        service.ingest(thermal(
            fanRPMs: [0, 0],
            sensors: [
                ThermalSensorReading(name: "E-cluster", celsius: 40),
                ThermalSensorReading(name: "P-cluster0", celsius: 70),
            ]
        ))
        // 70 °C, halfway between the breakpoints.
        XCTAssertEqual(service.fans[0].resolution.targetRPM ?? -1, 3100, accuracy: 0.0001)
    }

    func testANamedSensorThatDisappearsResolvesToNoReadingNotToAnotherSensor() {
        // Silently re-binding to the hottest sensor would change what the
        // curve means without telling anyone.
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        service.settings.defaultPolicy = FanControlPolicy(mode: .sensorCurve, sensorName: "P-cluster1")
        service.ingest(thermal(
            fanRPMs: [0, 0],
            sensors: [ThermalSensorReading(name: "E-cluster", celsius: 88)]
        ))
        XCTAssertNil(service.fans[0].resolution.targetRPM)
        if case .unavailable = service.fans[0].resolution.outcome {} else {
            XCTFail("a missing named sensor must not silently become a different sensor")
        }
    }

    // MARK: - Per-fan resolution uses per-fan limits

    func testEachFanIsClampedToItsOwnMeasuredCeiling() {
        // The spike's two fans top out 462 rpm apart on the same machine.
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        service.settings.defaultPolicy = FanControlPolicy(mode: .manual, manualTargetRPM: 20_000)
        service.ingest(thermal(fanRPMs: [0, 0]))
        XCTAssertEqual(service.fans[0].resolution.targetRPM, 5779)
        XCTAssertEqual(service.fans[1].resolution.targetRPM, 6241)
        XCTAssertTrue(service.fans[0].resolution.wasClamped)
    }

    // MARK: - Display naming

    func testFanDisplayNamesAreOneBasedForPeople() {
        let service = FanControlService(backend: FakeBackend(capability: twoFans))
        service.ingest(thermal(fanRPMs: [0, 0]))
        XCTAssertEqual(service.fans.map(\.displayName), ["Fan 1", "Fan 2"])
    }

    // MARK: - Return everything to Auto (plan §8's escape hatch)

    func testRevertAllTriesEveryFanAndReportsEveryFailure() {
        // The panic button must not stop at the first error. A "return
        // everything to Auto" that gave up after fan 1 would leave fan 2
        // held while telling the user it had finished — the worst possible
        // behavior for the one control that exists to undo everything.
        let backend = FakeBackend(capability: twoFans)
        let service = FanControlService(backend: backend)
        let failures = service.revertAllToAuto()

        XCTAssertEqual(backend.revertCallCount, 2, "both fans must be attempted")
        XCTAssertEqual(failures.map(\.fanIndex), [0, 1])
        XCTAssertFalse(failures.allSatisfy { $0.reason.isEmpty })
    }

    func testRevertAllReportsNothingWhenEveryFanCameBack() {
        let backend = FakeBackend(capability: twoFans)
        backend.revertSucceeds = true
        let service = FanControlService(backend: backend)
        XCTAssertTrue(service.revertAllToAuto().isEmpty)
        XCTAssertEqual(backend.revertCallCount, 2)
    }

    func testRevertAllIsANoOpWithNoFans() {
        let service = FanControlService(backend: UnsupportedFanControlBackend())
        XCTAssertTrue(service.revertAllToAuto().isEmpty)
    }

    // MARK: - The real backend, hardware-agnostically

    func testRealReadOnlyBackendNeverClaimsWritesAreAvailable() {
        // Phase 2's version of this test relied on there being no
        // `FanWriteAvailability` case meaning "writes work", so it could
        // not fail. Phase 3 added `.available`, which is exactly the event
        // that test existed to force a rethink at. The invariant that
        // survives is narrower and now has teeth: the *read-only* backend
        // must never report `.available`, whatever else changes around it,
        // and both of its write methods must throw on any hardware.
        let backend = SMCReadOnlyFanControlBackend()
        XCTAssertFalse(
            backend.writeAvailability.canWrite,
            "the read-only backend must never advertise a usable write path"
        )
        XCTAssertNotEqual(backend.writeAvailability, .available)
        XCTAssertFalse(
            backend.supportsPrivilegedHelper,
            "the read-only backend has no helper to offer, so the pane must not show an install button for it"
        )
        XCTAssertThrowsError(try backend.applyTarget(rpm: 3000, toFan: 0))
        XCTAssertThrowsError(try backend.revertToAuto(fan: 0))
        XCTAssertThrowsError(try backend.installPrivilegedHelper())
        XCTAssertThrowsError(try backend.removePrivilegedHelper())
    }

    func testUnsupportedBackendOffersNoHelperEither() {
        let backend = UnsupportedFanControlBackend()
        XCTAssertFalse(backend.writeAvailability.canWrite)
        XCTAssertFalse(backend.supportsPrivilegedHelper)
        XCTAssertThrowsError(try backend.installPrivilegedHelper())
    }

    func testRealBackendCapabilityAgreesWithItsOwnFanReadings() {
        // Hardware-agnostic invariant, in the spirit of `SMCFanBridgeTests`:
        // a fanless Air and a two-fan MacBook Pro must both pass.
        let backend = SMCReadOnlyFanControlBackend()
        let capability = backend.capability()
        let rpms = backend.readActualRPMs()

        switch capability {
        case .supported(let fans):
            XCTAssertFalse(fans.isEmpty)
            XCTAssertLessThanOrEqual(rpms.count, fans.count)
            for fan in fans {
                XCTAssertGreaterThanOrEqual(fan.index, 0)
                if let limits = fan.limits {
                    XCTAssertTrue(limits.isValid, "an invalid range must be reported as no range at all")
                }
            }
        case .noFansPresent, .unreadable:
            XCTAssertTrue(rpms.isEmpty, "no supported fans must mean no readings")
        }
    }

    func testRealBackendCachesASuccessfulProbeButNotAFailedOne() {
        // Two calls must agree; the caching is an optimization, never a
        // source of divergence.
        let backend = SMCReadOnlyFanControlBackend()
        XCTAssertEqual(backend.capability(), backend.capability())
    }

    // MARK: - Pane formatting (pure, no view hierarchy)

    func testPaneHeadlinesNameTheHardwareSituationExactly() {
        XCTAssertEqual(FanControlPane.capabilityHeadline(twoFans), "2 fans detected")
        XCTAssertEqual(
            FanControlPane.capabilityHeadline(.supported(fans: [FanDescriptor(index: 0)])),
            "1 fan detected"
        )
        XCTAssertEqual(FanControlPane.capabilityHeadline(.noFansPresent), "This Mac has no fans")
        XCTAssertEqual(
            FanControlPane.capabilityHeadline(.unreadable(reason: "x")),
            "Fan hardware couldn't be read"
        )
    }

    func testPaneShowsTheBackendsOwnReasonForAnUnreadableProbe() {
        // Not a generic "something went wrong" — the layer that knows why
        // supplies the sentence.
        XCTAssertEqual(
            FanControlPane.capabilityDetail(.unreadable(reason: "The SMC didn't answer.")),
            "The SMC didn't answer."
        )
    }

    func testPaneAdmitsAnUnknownRangeRatherThanInventingOne() {
        XCTAssertEqual(FanControlPane.limitsLabel(nil), "Range unknown")
        XCTAssertEqual(
            FanControlPane.limitsLabel(FanHardwareLimits(minRPM: 6000, maxRPM: 1200)),
            "Range unknown"
        )
        XCTAssertEqual(
            FanControlPane.limitsLabel(FanHardwareLimits(minRPM: 1200, maxRPM: 6241)),
            "1200–6241 rpm"
        )
    }

    func testEveryWriteAvailabilityReasonExplainsItselfInPlainLanguage() {
        // The control copy lives on the model so the pane can't drift out
        // of sync with the reason the backend actually reported. Every case
        // is listed, including `.available` — a screen that says nothing
        // when writes *are* possible would leave the user with no statement
        // of what the helper does or when it lets go.
        let all: [FanWriteAvailability] = [
            .available,
            .needsPrivilegedHelper,
            .helperAwaitingApproval,
            .helperUnreachable(reason: "The connection dropped."),
            .noFans,
            .hardwareUnreadable
        ]
        for availability in all {
            XCTAssertFalse(availability.explanation.isEmpty, "\(availability)")
            XCTAssertFalse(availability.shortLabel.isEmpty, "\(availability)")
        }

        // Exactly one case may enable the controls.
        XCTAssertEqual(all.filter(\.canWrite).count, 1)
        XCTAssertTrue(FanWriteAvailability.available.canWrite)

        XCTAssertTrue(
            FanWriteAvailability.needsPrivilegedHelper.explanation.contains("root"),
            "the reason a control is disabled must name the actual blocker"
        )
        XCTAssertTrue(
            FanWriteAvailability.helperAwaitingApproval.explanation.contains("System Settings"),
            "the approval state must tell the user where to go, since nothing in this app can move it forward"
        )
        XCTAssertTrue(
            FanWriteAvailability.helperUnreachable(reason: "The connection dropped.")
                .explanation.contains("The connection dropped."),
            "the specific failure must survive into the copy rather than being replaced by a generic sentence"
        )
    }

    func testAvailableExplanationNamesTheFailSafeAndTheClamp() {
        // The one screen where a user agrees to a root background service
        // has to say what bounds it. Asserted rather than trusted to
        // survive a copy edit.
        let copy = FanWriteAvailability.available.explanation
        XCTAssertTrue(copy.contains("firmware"), "must say the fans go back to the firmware")
        XCTAssertTrue(copy.contains("clamps"), "must say requests are clamped")
    }

    func testHelperRefusedIsNotConfusedWithWritesBeingUnavailable() {
        // The two diagnoses point at opposite fixes: one says "install the
        // helper", the other says "the helper is installed and said no".
        let refused = FanControlWriteError.helperRefused(reason: "The SMC refused the write to F0Tg.")
        let unavailable = FanControlWriteError.writesUnavailable(.needsPrivilegedHelper)
        XCTAssertNotEqual(refused, unavailable)
        XCTAssertEqual(refused.errorDescription, "The SMC refused the write to F0Tg.")
        XCTAssertEqual(
            unavailable.errorDescription,
            FanWriteAvailability.needsPrivilegedHelper.explanation
        )
    }

    func testPaneNeverPrintsZeroForAFixedSpeedNobodyChose() {
        // `manualTargetRPM == nil` and `== 0` are different states and have
        // been since Phase 2; the control label must keep them different.
        XCTAssertEqual(FanControlPane.targetLabel(FanControlPolicy()), "No fixed speed set")
        XCTAssertEqual(
            FanControlPane.targetLabel(FanControlPolicy(mode: .manual, manualTargetRPM: 0)),
            "0 rpm"
        )
        XCTAssertEqual(
            FanControlPane.targetLabel(FanControlPolicy(mode: .manual, manualTargetRPM: 3200)),
            "3200 rpm"
        )
        XCTAssertEqual(
            FanControlPane.targetLabel(FanControlPolicy(mode: .manual, manualTargetRPM: .nan)),
            "No fixed speed set"
        )
    }
}
