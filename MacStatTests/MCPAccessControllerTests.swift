import XCTest
@testable import MacStatKit

/// Covers `MCPAccessController.evaluate` and its rate limiter — the one
/// piece of the whole MCP surface (plan §13) that is a genuine security
/// boundary rather than a thin data adapter. The scenario this suite exists
/// to rule out: a write tool that's supposed to be "off by default" (plan
/// §13.4) executing anyway because some gate silently didn't apply. Every
/// test below asserts against `evaluate`'s pure decision, never against a
/// live XPC call or `MacStatMCP` process — `MCPXPCService` is the thing that
/// actually *enforces* these decisions against `PowerControlService`/
/// `AlertEngine`, but that requires an XPC connection and a running
/// `MacStat.app`, and isn't reasonably unit-testable; see this task's brief.
final class MCPAccessControllerTests: XCTestCase {

    // MARK: - Master switch

    func testMasterSwitchOffDeniesEvenAnEnabledReadTool() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = false

        let decision = controller.evaluate(tool: .getSystemSnapshot, settings: settings)

        XCTAssertEqual(decision, .denyMasterDisabled)
        XCTAssertTrue(decision.isDenied)
    }

    func testMasterSwitchOnAllowsADefaultEnabledReadTool() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true

        let decision = controller.evaluate(tool: .getSystemSnapshot, settings: settings)

        XCTAssertEqual(decision, .allow)
    }

    // MARK: - Write tools default off (the core "off by default" guarantee)

    func testWriteToolIsDeniedByDefaultEvenWithMasterSwitchOn() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        // `mcpWriteToolsEnabled` and per-tool membership both default off —
        // this is `AppSettings()`'s shipped configuration, not a hand-tuned
        // test fixture, so this test would fail the moment either default
        // silently flipped.
        XCTAssertFalse(settings.mcpWriteToolsEnabled)
        XCTAssertFalse(settings.mcpEnabledToolIDs.contains(MCPToolID.keepAwake.rawValue))

        let decision = controller.evaluate(tool: .keepAwake, settings: settings)

        XCTAssertTrue(decision.isDenied, "a write tool must never execute when disabled by default")
    }

    func testEnablingWriteToolsMasterSwitchAloneIsNotEnough() {
        // Plan §13.4's two-gate design: the coarse "allow write tools"
        // switch and each tool's own toggle are independent — flipping only
        // the coarse one must not silently enable every write tool.
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpWriteToolsEnabled = true
        // `keepAwake`'s own per-tool ID is deliberately left out of
        // `mcpEnabledToolIDs`.

        let decision = controller.evaluate(tool: .keepAwake, settings: settings)

        XCTAssertEqual(decision, .denyToolDisabled)
    }

    func testEnablingBothGatesAllowsTheWriteToolToExecute() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpWriteToolsEnabled = true
        settings.mcpEnabledToolIDs.insert(MCPToolID.keepAwake.rawValue)

        let decision = controller.evaluate(tool: .keepAwake, settings: settings)

        XCTAssertEqual(decision, .allow)
    }

    func testDisablingMasterWriteSwitchDeniesAWriteToolEvenIfItsOwnToggleIsOn() {
        // The reverse of the two tests above: an individually-enabled write
        // tool must still be blocked if the coarser "allow write tools"
        // switch is off — a user turning that master switch off must be a
        // reliable "no write tool runs," not something a stale per-tool flag
        // can defeat.
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpWriteToolsEnabled = false
        settings.mcpEnabledToolIDs.insert(MCPToolID.releaseAwake.rawValue)

        let decision = controller.evaluate(tool: .releaseAwake, settings: settings)

        XCTAssertEqual(decision, .denyToolDisabled)
    }

    // MARK: - Read tools default on

    func testEveryReadToolIsEnabledByDefault() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true

        for tool in MCPToolID.readTools {
            XCTAssertEqual(
                controller.evaluate(tool: tool, settings: settings),
                .allow,
                "\(tool.rawValue) should be allowed by default when MCP is enabled"
            )
        }
    }

    func testEveryWriteToolIsDisabledByDefault() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpWriteToolsEnabled = true // isolate the per-tool gate specifically

        for tool in MCPToolID.writeTools {
            XCTAssertTrue(
                controller.evaluate(tool: tool, settings: settings).isDenied,
                "\(tool.rawValue) should be disabled by default"
            )
        }
    }

    // MARK: - Per-tool disable overrides the master read/write switch

    func testIndividuallyDisablingAReadToolDeniesItEvenThoughReadToolsDefaultOn() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpEnabledToolIDs.remove(MCPToolID.getBatteryStatus.rawValue)

        let decision = controller.evaluate(tool: .getBatteryStatus, settings: settings)

        XCTAssertEqual(decision, .denyToolDisabled)
    }

    // MARK: - Confirmation

    func testWriteToolRequiringConfirmationReturnsThatDecisionRatherThanAllowingOutright() {
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpWriteToolsEnabled = true
        settings.mcpEnabledToolIDs.insert(MCPToolID.createAlertRule.rawValue)
        settings.mcpConfirmationRequiredToolIDs.insert(MCPToolID.createAlertRule.rawValue)

        let decision = controller.evaluate(tool: .createAlertRule, settings: settings)

        XCTAssertEqual(decision, .requiresConfirmation)
        XCTAssertFalse(decision.isDenied, "pending confirmation is not itself a denial")
    }

    func testConfirmationRequirementOnAReadToolIDIsIgnored() {
        // `mcpConfirmationRequiredToolIDs` is only ever consulted for write
        // tools (see `evaluate`'s doc comment) — a read tool's ID present in
        // that set (e.g. from a hand-edited settings file) must not block a
        // read tool that would otherwise be allowed.
        let controller = MCPAccessController()
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpConfirmationRequiredToolIDs.insert(MCPToolID.getDeviceInfo.rawValue)

        let decision = controller.evaluate(tool: .getDeviceInfo, settings: settings)

        XCTAssertEqual(decision, .allow)
    }

    // MARK: - Rate limiting

    func testRateLimitAllowsExactlyTheConfiguredCallsPerMinute() {
        var now = Date()
        let controller = MCPAccessController(clock: { now })
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpRateLimitPerMinute = 3

        for i in 0..<3 {
            XCTAssertEqual(
                controller.evaluate(tool: .getSystemSnapshot, settings: settings),
                .allow,
                "call \(i) should be within the limit"
            )
            controller.recordCall()
        }

        XCTAssertEqual(
            controller.evaluate(tool: .getSystemSnapshot, settings: settings),
            .denyRateLimited,
            "the 4th call within the same window must be rejected"
        )
        _ = now // silence "never mutated" warning; kept as a var for readability/intent
    }

    func testRateLimitWindowExpiresAfterSixtySeconds() {
        var now = Date()
        let controller = MCPAccessController(clock: { now })
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpRateLimitPerMinute = 1

        XCTAssertEqual(controller.evaluate(tool: .getSystemSnapshot, settings: settings), .allow)
        controller.recordCall()
        XCTAssertEqual(controller.evaluate(tool: .getSystemSnapshot, settings: settings), .denyRateLimited)

        // Move the clock forward past the 60s window.
        now = now.addingTimeInterval(61)

        XCTAssertEqual(
            controller.evaluate(tool: .getSystemSnapshot, settings: settings),
            .allow,
            "the rate limit window should have rolled over"
        )
    }

    func testDeclinedConfirmationDoesNotConsumeRateLimitBudget() {
        // `recordCall()` is only supposed to be invoked by the caller once a
        // call is genuinely about to execute (see its doc comment) — a
        // confirmation the user declines must not eat into the same budget
        // an executed call would.
        let now = Date()
        let controller = MCPAccessController(clock: { now })
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpRateLimitPerMinute = 1

        // Simulate: evaluate → requiresConfirmation → user declines →
        // caller never calls recordCall().
        settings.mcpWriteToolsEnabled = true
        settings.mcpEnabledToolIDs.insert(MCPToolID.keepAwake.rawValue)
        settings.mcpConfirmationRequiredToolIDs.insert(MCPToolID.keepAwake.rawValue)
        XCTAssertEqual(controller.evaluate(tool: .keepAwake, settings: settings), .requiresConfirmation)
        // No recordCall() here — the user said no.

        // The rate limit budget (1/min) should still be fully available.
        XCTAssertFalse(controller.isRateLimited(limitPerMinute: 1))
    }

    func testRateLimitIsSharedAcrossDifferentTools() {
        // Plan §13.4: "max N tool calls/minute" — one shared window across
        // every tool, not a separate budget per tool (otherwise a client
        // could dodge the cap by alternating tools).
        let now = Date()
        let controller = MCPAccessController(clock: { now })
        var settings = AppSettings()
        settings.mcpServerEnabled = true
        settings.mcpRateLimitPerMinute = 1

        XCTAssertEqual(controller.evaluate(tool: .getSystemSnapshot, settings: settings), .allow)
        controller.recordCall()

        XCTAssertEqual(
            controller.evaluate(tool: .getDeviceInfo, settings: settings),
            .denyRateLimited,
            "a different tool must still be blocked by the same shared window"
        )
    }

    // MARK: - AppSettings defaults sanity (guards the controller's own assumptions)

    func testDefaultMCPEnabledToolIDsContainsExactlyTheReadTools() {
        XCTAssertEqual(
            AppSettings.defaultMCPEnabledToolIDs,
            Set(MCPToolID.readTools.map(\.rawValue))
        )
    }
}
