import XCTest
import ServiceManagement
@testable import MacStatKit

/// Pins the three-strings-are-one-string contract of `MCPAgentNaming` and
/// exercises every `MCPAgentRegistrar` transition through its injected
/// seams — the same technique `PrivilegedFanControlBackend` uses, and for
/// the same reason: on a machine with no signing identity every real
/// `SMAppService` query answers `.notFound`, so only injected statuses can
/// reach the other branches.
final class MCPAgentRegistrationTests: XCTestCase {

    // MARK: - Naming

    /// The label, the Mach service name, and the plist basename must be
    /// the same string — the plist's `Label` and `MachServices` keys and
    /// `LaunchAgent/dev.malekswilam.macstat.xpc.plist`'s file name are all
    /// hand-written copies of it. A failure here names the files to fix.
    func testNamingTripleAgreement() {
        XCTAssertEqual(MCPAgentNaming.label, "dev.malekswilam.macstat.xpc")
        XCTAssertEqual(MCPAgentNaming.label, MacStatXPCServiceName.machService)
        XCTAssertEqual(MCPAgentNaming.plistName, "dev.malekswilam.macstat.xpc.plist")
    }

    // MARK: - Status mapping

    func testStatusMapping() {
        XCTAssertEqual(MCPAgentStatusMap.status(for: .enabled), .registered)
        XCTAssertEqual(MCPAgentStatusMap.status(for: .requiresApproval), .requiresApproval)
        XCTAssertEqual(MCPAgentStatusMap.status(for: .notRegistered), .notRegistered)
        guard case .unavailable(let reason) = MCPAgentStatusMap.status(for: .notFound) else {
            return XCTFail("`.notFound` must map to `.unavailable` with a reason")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Registrar transitions

    @MainActor
    func testRegisterSuccessRefreshesStatus() {
        var launchdState: SMAppService.Status = .notRegistered
        let registrar = MCPAgentRegistrar(
            probe: { launchdState },
            registerAction: { launchdState = .enabled },
            unregisterAction: { launchdState = .notRegistered }
        )
        XCTAssertEqual(registrar.status, .notRegistered)
        XCTAssertNil(registrar.register())
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertNil(registrar.unregister())
        XCTAssertEqual(registrar.status, .notRegistered)
    }

    /// "Success" includes launchd parking the agent behind user approval —
    /// `register()` must not report that as an error, and the status must
    /// say what the user still has to do.
    @MainActor
    func testRegisterLandingInRequiresApprovalIsNotAnError() {
        var launchdState: SMAppService.Status = .notRegistered
        let registrar = MCPAgentRegistrar(
            probe: { launchdState },
            registerAction: { launchdState = .requiresApproval },
            unregisterAction: {}
        )
        XCTAssertNil(registrar.register())
        XCTAssertEqual(registrar.status, .requiresApproval)
    }

    /// The known real-world throw: an ad-hoc build `SMAppService` refuses.
    /// The message must surface, and the status must re-read launchd's
    /// answer rather than optimistically flipping.
    @MainActor
    func testRegisterFailureSurfacesMessageAndKeepsHonestStatus() {
        struct Refused: LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        let registrar = MCPAgentRegistrar(
            probe: { .notRegistered },
            registerAction: { throw Refused() },
            unregisterAction: {}
        )
        let message = registrar.register()
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Operation not permitted") == true)
        XCTAssertEqual(registrar.status, .notRegistered)
    }

    @MainActor
    func testRefreshTracksExternalChanges() {
        // The user can revoke approval in System Settings while Sentry
        // runs; nothing pushes that to us, so refresh() must pull it.
        var launchdState: SMAppService.Status = .enabled
        let registrar = MCPAgentRegistrar(probe: { launchdState }, registerAction: {}, unregisterAction: {})
        XCTAssertEqual(registrar.status, .registered)
        launchdState = .notRegistered
        registrar.refresh()
        XCTAssertEqual(registrar.status, .notRegistered)
    }
}
