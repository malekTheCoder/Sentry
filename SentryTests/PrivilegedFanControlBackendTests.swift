import XCTest
import ServiceManagement
@testable import SentryKit
@testable import SystemMetricsKit

/// The app-side half of the privileged path: the decision table that turns
/// `SMAppService.Status` plus the hardware's own answer into a
/// `FanWriteAvailability`, and the guarantee that nothing about the helper
/// can change what the app reports about this Mac's fans.
///
/// **`statusProbe` is injected for a reason that is not "unit tests are
/// nice".** On a machine with no signing identities `SMAppService` can only
/// ever report `.notRegistered` for this daemon, so five of the six rows in
/// the table below would be permanently unreachable and permanently
/// untested. Injecting the probe is what makes the table testable at all;
/// production passes `nil` and consults the real service.
///
/// **Not covered here, and not coverable from this branch:** registration
/// actually succeeding, an XPC connection actually being established, and
/// any SMC write. See `FanDaemonContract`.
final class PrivilegedFanControlBackendTests: XCTestCase {

    /// Stands in for `SMCReadOnlyFanControlBackend`, which answers whatever
    /// the machine running the suite happens to be — the same reason
    /// `FanControlServiceTests` fakes its backends.
    private final class FakeReadBackend: FanControlBackend {
        let identifier = "fake-read"
        var reportedCapability: FanControlCapability
        var reportedRPMs: [Double]
        private(set) var rpmReadCount = 0

        init(capability: FanControlCapability, rpms: [Double] = []) {
            self.reportedCapability = capability
            self.reportedRPMs = rpms
        }

        func capability() -> FanControlCapability { reportedCapability }
        func readActualRPMs() -> [Double] {
            rpmReadCount += 1
            return reportedRPMs
        }
        var writeAvailability: FanWriteAvailability { .needsPrivilegedHelper }
        func applyTarget(rpm: Double, toFan index: Int) throws {
            throw FanControlWriteError.writesUnavailable(.needsPrivilegedHelper)
        }
        func revertToAuto(fan index: Int) throws {
            throw FanControlWriteError.writesUnavailable(.needsPrivilegedHelper)
        }
    }

    private let twoFans = FanControlCapability.supported(fans: [
        FanDescriptor(index: 0, limits: FanHardwareLimits(minRPM: 1200, maxRPM: 5779)),
        FanDescriptor(index: 1, limits: FanHardwareLimits(minRPM: 1200, maxRPM: 6241))
    ])

    private func backend(
        capability: FanControlCapability,
        status: SMAppService.Status,
        rpms: [Double] = []
    ) -> (PrivilegedFanControlBackend, FakeReadBackend) {
        let reading = FakeReadBackend(capability: capability, rpms: rpms)
        return (PrivilegedFanControlBackend(reading: reading, statusProbe: { status }), reading)
    }

    // MARK: - The inert default

    func testAnUnregisteredHelperLeavesTheAppExactlyWhereItWasBeforePhase3() {
        // The property that makes this branch safe to merge before signing
        // certificates exist: with no helper registered, the privileged
        // backend is indistinguishable from the read-only one.
        let (privileged, _) = backend(capability: twoFans, status: .notRegistered)

        XCTAssertEqual(privileged.writeAvailability, .needsPrivilegedHelper)
        XCTAssertFalse(privileged.writeAvailability.canWrite)
        XCTAssertThrowsError(try privileged.applyTarget(rpm: 3000, toFan: 0)) { error in
            XCTAssertEqual(
                error as? FanControlWriteError,
                .writesUnavailable(.needsPrivilegedHelper),
                "an unregistered helper must refuse before any connection is attempted"
            )
        }
        XCTAssertThrowsError(try privileged.revertToAuto(fan: 0)) { error in
            XCTAssertEqual(error as? FanControlWriteError, .writesUnavailable(.needsPrivilegedHelper))
        }
    }

    func testAMissingHelperReadsTheSameAsAPresentOne() {
        // Reads must never travel through the privileged path, so a helper
        // that is absent, broken, or removed cannot change a single number
        // the Fans pane shows.
        for status: SMAppService.Status in [.notRegistered, .notFound, .requiresApproval, .enabled] {
            let (privileged, reading) = backend(
                capability: twoFans,
                status: status,
                rpms: [1780, 0]
            )
            XCTAssertEqual(privileged.capability(), twoFans, "\(status)")
            XCTAssertEqual(privileged.readActualRPMs(), [1780, 0], "\(status)")
            XCTAssertGreaterThan(reading.rpmReadCount, 0, "the read must be forwarded, not synthesised")
        }
    }

    func testReturningEveryFanToFirmwareIsANoOpWithNoHelper() {
        // Called from `applicationWillTerminate` on every quit, including
        // the overwhelming majority where no helper was ever installed. It
        // must not throw, hang, or attempt a connection.
        let (privileged, _) = backend(capability: twoFans, status: .notRegistered)
        privileged.returnEveryFanToFirmware()
    }

    // MARK: - The decision table

    func testHardwareFactsOutrankHelperFacts() {
        // A fanless Air with a perfectly healthy helper still has nothing
        // to write to, and telling its owner to approve a background item
        // would send them to fix the wrong thing.
        let (fanless, _) = backend(capability: .noFansPresent, status: .enabled)
        XCTAssertEqual(fanless.writeAvailability, .noFans)
        XCTAssertFalse(fanless.supportsPrivilegedHelper, "no install button on a Mac with no fans")

        let (unreadable, _) = backend(
            capability: .unreadable(reason: "The SMC didn't answer."),
            status: .enabled
        )
        XCTAssertEqual(unreadable.writeAvailability, .hardwareUnreadable)
        XCTAssertFalse(unreadable.supportsPrivilegedHelper)
    }

    func testAwaitingApprovalIsItsOwnStateAndNotConfusedWithNotInstalled() {
        // Different states, different instructions: one says "press
        // Install", the other says "you already did — go approve it".
        let (privileged, _) = backend(capability: twoFans, status: .requiresApproval)
        XCTAssertEqual(privileged.writeAvailability, .helperAwaitingApproval)
        XCTAssertFalse(privileged.writeAvailability.canWrite)
    }

    func testNotFoundReadsAsNotInstalledRatherThanAsAFailure() {
        // `.notFound` means macOS has no record of the plist — which, for a
        // user, is the same situation as never having installed it, and
        // the same fix.
        let (privileged, _) = backend(capability: twoFans, status: .notFound)
        XCTAssertEqual(privileged.writeAvailability, .needsPrivilegedHelper)
    }

    func testAnEnabledHelperOnHardwareWithFansIsTheOneWritableCombination() {
        let (privileged, _) = backend(capability: twoFans, status: .enabled)
        XCTAssertEqual(privileged.writeAvailability, .available)
        XCTAssertTrue(privileged.writeAvailability.canWrite)
        XCTAssertTrue(privileged.supportsPrivilegedHelper)
    }

    func testTheInstallAffordanceIsOfferedOnlyWhereItCouldDoSomething() {
        let (withFans, _) = backend(capability: twoFans, status: .notRegistered)
        XCTAssertTrue(withFans.supportsPrivilegedHelper)

        let (withoutFans, _) = backend(capability: .noFansPresent, status: .notRegistered)
        XCTAssertFalse(withoutFans.supportsPrivilegedHelper)
    }

    func testTheBackendIdentifiesItselfForBugReports() {
        let (privileged, _) = backend(capability: twoFans, status: .enabled)
        XCTAssertEqual(privileged.identifier, "privileged-helper")
    }

    // MARK: - The real composition, on whatever machine runs this suite

    func testTheRealCompositionIsInertUntilSomebodyInstallsTheHelper() {
        // The exact object graph `AppDelegate` builds — real SMC reads, real
        // `SMAppService` probe, no injection. It asserts the property this
        // whole branch was designed around: on a machine where the helper is
        // not installed (which is every machine until a person presses a
        // button, and *necessarily* every machine with no signing
        // certificates), constructing and using the privileged backend
        // changes nothing.
        //
        // Deliberately hardware-agnostic, in the spirit of
        // `SMCFanBridgeTests`: a fanless Air, a two-fan MacBook Pro, and a
        // CI box whose SMC refuses must all pass. What is asserted is the
        // *relationship* between the two backends, not this developer's fan
        // count.
        let reading = SMCReadOnlyFanControlBackend()
        let privileged = PrivilegedFanControlBackend(reading: reading)

        XCTAssertEqual(
            privileged.capability(),
            reading.capability(),
            "the privileged wrapper must not change what the app knows about this Mac's fans"
        )
        XCTAssertEqual(privileged.readActualRPMs().count, reading.readActualRPMs().count)

        // No helper is registered on any machine that has merely checked
        // this branch out, so writes must be refused — and refused with a
        // reason about the *helper*, never a claim about the hardware.
        switch privileged.writeAvailability {
        case .available:
            // Would mean a helper really is registered and enabled on this
            // machine. Not a failure of the code, but it invalidates the
            // premise of the rest of this test, so it stops here loudly
            // rather than asserting something meaningless.
            XCTFail("this suite assumes no fan helper is installed; one appears to be registered")
        case .needsPrivilegedHelper, .helperAwaitingApproval, .helperUnreachable:
            XCTAssertFalse(privileged.writeAvailability.canWrite)
            XCTAssertThrowsError(try privileged.applyTarget(rpm: 3000, toFan: 0))
            XCTAssertThrowsError(try privileged.revertToAuto(fan: 0))
        case .noFans, .hardwareUnreadable:
            // A fanless or unreadable Mac. Still inert, and still must not
            // blame a missing helper for a hardware fact.
            XCTAssertFalse(privileged.writeAvailability.canWrite)
            XCTAssertFalse(privileged.supportsPrivilegedHelper)
        }

        // Called on every quit from `applicationWillTerminate`. Must be a
        // silent no-op with nothing installed.
        privileged.returnEveryFanToFirmware()
    }

    func testRefreshingHelperStatusOnAMachineWithNoHelperChangesNothing() {
        // The Fans pane calls this on every appearance. It must be cheap,
        // prompt nothing, and never flip the app into a writable state by
        // itself.
        let privileged = PrivilegedFanControlBackend(reading: SMCReadOnlyFanControlBackend())
        let before = privileged.writeAvailability
        privileged.refreshWriteAvailability()
        privileged.refreshWriteAvailability()
        XCTAssertEqual(privileged.writeAvailability, before)
        XCTAssertFalse(privileged.writeAvailability.canWrite)
    }

    // MARK: - The describe payload

    func testTheDaemonsDescriptionRoundTripsThroughItsWireFormat() {
        // JSON over XPC, matching `MCPPayloads`' convention. A fan whose
        // range wouldn't read keeps its `nil`s rather than gaining zeroes —
        // "unknown" and "0 rpm" are different answers and stay different
        // all the way across the boundary.
        let original = FanDaemonDescription(
            fans: [
                .init(index: 0, minRPM: 1200, maxRPM: 5779, isHeldByDaemon: true),
                .init(index: 1, minRPM: nil, maxRPM: nil, isHeldByDaemon: false)
            ],
            uptimeSeconds: 42.5
        )
        let data = try? JSONEncoder().encode(original)
        XCTAssertNotNil(data)
        let decoded = data.flatMap { try? JSONDecoder().decode(FanDaemonDescription.self, from: $0) }
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded?.fans[1].minRPM)
    }
}
