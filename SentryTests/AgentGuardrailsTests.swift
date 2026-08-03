import XCTest
@testable import SentryKit

/// Unit tests for the pure guardrail policy engine
/// (`SentryKit/Services/AgentGuardrails.swift`) — every verdict here is a
/// function of (settings, fabricated power/thermal context, pinned clock),
/// with no service, IOKit, or XPC involvement, mirroring
/// `MCPAccessControllerTests`' posture for the static permission model.
/// Enforcement (that `MCPXPCService.authorize` actually consults these
/// verdicts) is a separate concern covered by that service's guard structure;
/// these tests pin down the *decisions*, including every boundary the brief
/// calls out: exactly at the battery floor, quiet hours crossing midnight,
/// and the plugged-in override.
final class AgentGuardrailsTests: XCTestCase {

    /// A fixed calendar/timezone so quiet-hours tests don't inherit the
    /// build machine's locale.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }()

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: hour, minute: minute))!
    }

    private func context(
        batteryPercent: Double? = nil,
        isPluggedIn: Bool? = nil,
        thermalPressure: ThermalStats.PressureLevel? = nil,
        hour: Int = 12,
        minute: Int = 0
    ) -> AgentGuardrails.PowerContext {
        AgentGuardrails.PowerContext(
            batteryPercent: batteryPercent,
            isPluggedIn: isPluggedIn,
            thermalPressure: thermalPressure,
            date: date(hour: hour, minute: minute),
            calendar: calendar
        )
    }

    private func verdict(
        tool: MCPToolID = .keepAwake,
        clientName: String = "TestClient",
        settings: AgentGuardrailSettings = AgentGuardrailSettings(),
        context: AgentGuardrails.PowerContext
    ) -> AgentGuardrails.Verdict {
        AgentGuardrails.evaluate(tool: tool, clientName: clientName, settings: settings, context: context)
    }

    private func assertDenied(
        _ verdict: AgentGuardrails.Verdict,
        containing fragment: String? = nil,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .deny(let reason) = verdict else {
            XCTFail("expected denial \(message)", file: file, line: line)
            return
        }
        if let fragment {
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains(fragment),
                "denial reason \"\(reason)\" should mention \"\(fragment)\"",
                file: file, line: line
            )
        }
    }

    // MARK: - Battery floor

    func testKeepAwakeDeniedBelowFloorWhileUnplugged() {
        let result = verdict(context: context(batteryPercent: 14, isPluggedIn: false))
        assertDenied(result, containing: "14%", "battery below the default 20% floor, unplugged")
        assertDenied(result, containing: "unplugged")
    }

    func testKeepAwakeAllowedExactlyAtFloor() {
        // "Below N%" is strict — exactly N% passes.
        XCTAssertEqual(verdict(context: context(batteryPercent: 20, isPluggedIn: false)), .allow)
    }

    func testKeepAwakeAllowedBelowFloorWhenPluggedIn() {
        XCTAssertEqual(verdict(context: context(batteryPercent: 5, isPluggedIn: true)), .allow)
    }

    func testKeepAwakeAllowedBelowFloorWhenFloorDisabled() {
        let settings = AgentGuardrailSettings(batteryFloorEnabled: false)
        XCTAssertEqual(verdict(settings: settings, context: context(batteryPercent: 5, isPluggedIn: false)), .allow)
    }

    func testFloorRespectsConfiguredThreshold() {
        let settings = AgentGuardrailSettings(batteryFloorPercent: 50)
        assertDenied(verdict(settings: settings, context: context(batteryPercent: 49, isPluggedIn: false)))
        XCTAssertEqual(verdict(settings: settings, context: context(batteryPercent: 50, isPluggedIn: false)), .allow)
    }

    func testFloorOnlyGatesKeepAwakeByDefault() {
        let low = context(batteryPercent: 5, isPluggedIn: false)
        XCTAssertEqual(verdict(tool: .setAlertRuleEnabled, context: low), .allow)
        XCTAssertEqual(verdict(tool: .setRefreshInterval, context: low), .allow)
    }

    func testFloorGatesAllWriteToolsWhenWidened() {
        let settings = AgentGuardrailSettings(batteryFloorAppliesToAllWriteTools: true)
        let low = context(batteryPercent: 5, isPluggedIn: false)
        assertDenied(verdict(tool: .setAlertRuleEnabled, settings: settings, context: low))
        assertDenied(verdict(tool: .createAlertRule, settings: settings, context: low))
        // Read tools stay outside conditional policies even when widened.
        XCTAssertEqual(verdict(tool: .getBatteryStatus, settings: settings, context: low), .allow)
    }

    func testMissingBatteryDataNeverDenies() {
        // A desktop Mac (no battery) or a pre-first-sample snapshot must not
        // trip the floor — absence is not "on battery."
        XCTAssertEqual(verdict(context: context(batteryPercent: nil, isPluggedIn: nil)), .allow)
        XCTAssertEqual(verdict(context: context(batteryPercent: nil, isPluggedIn: false)), .allow)
    }

    // MARK: - On-battery restriction

    func testOnBatteryRestrictionDeniesEveryWriteTool() {
        let settings = AgentGuardrailSettings(denyWriteToolsOnBattery: true)
        let onBattery = context(batteryPercent: 90, isPluggedIn: false)
        for tool in MCPToolID.writeTools {
            assertDenied(
                verdict(tool: tool, settings: settings, context: onBattery),
                containing: "battery",
                "\(tool.rawValue) on battery with the restriction on"
            )
        }
    }

    func testOnBatteryRestrictionLeavesReadToolsAlone() {
        let settings = AgentGuardrailSettings(denyWriteToolsOnBattery: true)
        let onBattery = context(batteryPercent: 90, isPluggedIn: false)
        for tool in MCPToolID.readTools {
            XCTAssertEqual(verdict(tool: tool, settings: settings, context: onBattery), .allow, tool.rawValue)
        }
    }

    func testOnBatteryRestrictionAllowsWhenPluggedInOrUnknown() {
        let settings = AgentGuardrailSettings(denyWriteToolsOnBattery: true)
        XCTAssertEqual(verdict(settings: settings, context: context(isPluggedIn: true)), .allow)
        XCTAssertEqual(verdict(settings: settings, context: context(isPluggedIn: nil)), .allow)
    }

    // MARK: - Quiet hours

    private var overnightQuietHours: AgentGuardrailSettings {
        // 22:00–07:00, the shipped default window, explicitly enabled.
        AgentGuardrailSettings(quietHoursEnabled: true, quietHoursStartMinute: 22 * 60, quietHoursEndMinute: 7 * 60)
    }

    func testQuietHoursCrossingMidnightDenyLateEvening() {
        assertDenied(
            verdict(settings: overnightQuietHours, context: context(isPluggedIn: true, hour: 23)),
            containing: "quiet hours"
        )
    }

    func testQuietHoursCrossingMidnightDenyEarlyMorning() {
        assertDenied(verdict(settings: overnightQuietHours, context: context(hour: 3)))
    }

    func testQuietHoursCrossingMidnightAllowMidday() {
        XCTAssertEqual(verdict(settings: overnightQuietHours, context: context(hour: 12)), .allow)
    }

    func testQuietHoursBoundariesAreStartInclusiveEndExclusive() {
        // 22:00 exactly is inside; 07:00 exactly is the first free minute.
        assertDenied(verdict(settings: overnightQuietHours, context: context(hour: 22, minute: 0)))
        XCTAssertEqual(verdict(settings: overnightQuietHours, context: context(hour: 7, minute: 0)), .allow)
        assertDenied(verdict(settings: overnightQuietHours, context: context(hour: 6, minute: 59)))
    }

    func testQuietHoursSameDayWindow() {
        let settings = AgentGuardrailSettings(quietHoursEnabled: true, quietHoursStartMinute: 9 * 60, quietHoursEndMinute: 17 * 60)
        assertDenied(verdict(settings: settings, context: context(hour: 12)))
        XCTAssertEqual(verdict(settings: settings, context: context(hour: 8)), .allow)
        XCTAssertEqual(verdict(settings: settings, context: context(hour: 17)), .allow)
    }

    func testQuietHoursZeroLengthWindowIsNeverActive() {
        let settings = AgentGuardrailSettings(quietHoursEnabled: true, quietHoursStartMinute: 600, quietHoursEndMinute: 600)
        XCTAssertEqual(verdict(settings: settings, context: context(hour: 10)), .allow)
    }

    func testQuietHoursOnlyGateKeepAwake() {
        // "No agent may hold keep-awake" — other write tools stay usable.
        XCTAssertEqual(verdict(tool: .setRefreshInterval, settings: overnightQuietHours, context: context(hour: 23)), .allow)
    }

    func testQuietHoursDisabledAllowAlways() {
        var settings = overnightQuietHours
        settings.quietHoursEnabled = false
        XCTAssertEqual(verdict(settings: settings, context: context(hour: 23)), .allow)
    }

    // MARK: - Thermal

    func testKeepAwakeDeniedUnderSeriousAndCriticalPressure() {
        assertDenied(verdict(context: context(thermalPressure: .serious)), containing: "thermal")
        assertDenied(verdict(context: context(thermalPressure: .critical)))
    }

    func testKeepAwakeAllowedUnderNominalAndFairPressure() {
        XCTAssertEqual(verdict(context: context(thermalPressure: .nominal)), .allow)
        XCTAssertEqual(verdict(context: context(thermalPressure: .fair)), .allow)
    }

    func testThermalGateOnlyAppliesToKeepAwake() {
        XCTAssertEqual(verdict(tool: .createAlertRule, context: context(thermalPressure: .critical)), .allow)
    }

    func testThermalGateDisabledAllows() {
        let settings = AgentGuardrailSettings(thermalAutoRevokeEnabled: false)
        XCTAssertEqual(verdict(settings: settings, context: context(thermalPressure: .critical)), .allow)
    }

    // MARK: - Kill switch + per-client revocation

    func testKillSwitchDeniesEveryToolForEveryClient() {
        let settings = AgentGuardrailSettings(killSwitchEngaged: true)
        for tool in MCPToolID.allCases {
            assertDenied(
                verdict(tool: tool, settings: settings, context: context()),
                containing: "paused",
                "\(tool.rawValue) with the kill switch engaged"
            )
        }
    }

    func testRevokedClientDeniedReadAndWriteWhileOthersPass() {
        let settings = AgentGuardrailSettings(revokedClientNames: ["Claude Code"])
        assertDenied(
            verdict(tool: .getSystemSnapshot, clientName: "Claude Code", settings: settings, context: context()),
            containing: "Claude Code"
        )
        assertDenied(verdict(tool: .keepAwake, clientName: "Claude Code", settings: settings, context: context()))
        XCTAssertEqual(verdict(tool: .getSystemSnapshot, clientName: "Cursor", settings: settings, context: context()), .allow)
    }

    // MARK: - Auto-revocation

    func testNoRevocationUnderNormalConditions() {
        XCTAssertNil(AgentGuardrails.autoRevocationReason(
            settings: AgentGuardrailSettings(),
            context: context(batteryPercent: 80, isPluggedIn: true, thermalPressure: .nominal)
        ))
    }

    func testQuietHoursStartTriggersRevocation() {
        let reason = AgentGuardrails.autoRevocationReason(
            settings: overnightQuietHours,
            context: context(hour: 22, minute: 0)
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("quiet hours") == true)
    }

    func testQuietHoursOutsideWindowDoesNotRevoke() {
        XCTAssertNil(AgentGuardrails.autoRevocationReason(settings: overnightQuietHours, context: context(hour: 12)))
    }

    func testThermalPressureTriggersRevocationAtSeriousAndAbove() {
        XCTAssertNotNil(AgentGuardrails.autoRevocationReason(settings: AgentGuardrailSettings(), context: context(thermalPressure: .serious)))
        XCTAssertNotNil(AgentGuardrails.autoRevocationReason(settings: AgentGuardrailSettings(), context: context(thermalPressure: .critical)))
        XCTAssertNil(AgentGuardrails.autoRevocationReason(settings: AgentGuardrailSettings(), context: context(thermalPressure: .fair)))
    }

    func testThermalRevocationRespectsToggle() {
        XCTAssertNil(AgentGuardrails.autoRevocationReason(
            settings: AgentGuardrailSettings(thermalAutoRevokeEnabled: false),
            context: context(thermalPressure: .critical)
        ))
    }

    func testKillSwitchTriggersRevocation() {
        XCTAssertNotNil(AgentGuardrails.autoRevocationReason(
            settings: AgentGuardrailSettings(killSwitchEngaged: true),
            context: context()
        ))
    }

    // MARK: - Denial ordering

    func testKillSwitchReasonWinsOverEveryOtherCondition() {
        // The broadest applicable reason is the one the agent should read.
        var settings = overnightQuietHours
        settings.killSwitchEngaged = true
        settings.denyWriteToolsOnBattery = true
        let worstCase = context(batteryPercent: 3, isPluggedIn: false, thermalPressure: .critical, hour: 23)
        assertDenied(verdict(settings: settings, context: worstCase), containing: "paused")
    }

    // MARK: - Settings persistence

    func testGuardrailSettingsDefaultsSurviveEmptyJSON() throws {
        // A settings block written before any guardrail field existed (or an
        // AppSettings file predating the block entirely) must decode to the
        // shipped defaults, not zeroes.
        let decoded = try JSONDecoder().decode(AgentGuardrailSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AgentGuardrailSettings())
        XCTAssertFalse(decoded.killSwitchEngaged)
        XCTAssertTrue(decoded.batteryFloorEnabled)
        XCTAssertEqual(decoded.batteryFloorPercent, 20)
        XCTAssertFalse(decoded.denyWriteToolsOnBattery)
        XCTAssertFalse(decoded.quietHoursEnabled)
        XCTAssertEqual(decoded.quietHoursStartMinute, 22 * 60)
        XCTAssertEqual(decoded.quietHoursEndMinute, 7 * 60)
        XCTAssertTrue(decoded.thermalAutoRevokeEnabled)
    }

    func testAppSettingsMissingGuardrailKeyUpgradesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.agentGuardrails, AgentGuardrailSettings())
    }

    func testGuardrailSettingsRoundTripThroughAppSettings() throws {
        var settings = AppSettings()
        settings.agentGuardrails.killSwitchEngaged = true
        settings.agentGuardrails.revokedClientNames = ["Claude Code", "Cursor"]
        settings.agentGuardrails.batteryFloorPercent = 35
        settings.agentGuardrails.quietHoursEnabled = true
        settings.agentGuardrails.quietHoursStartMinute = 21 * 60 + 30

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.agentGuardrails, settings.agentGuardrails)
    }

    // MARK: - Formatting

    func testFormattedMinuteRenders24HourClock() {
        XCTAssertEqual(AgentGuardrails.formattedMinute(0), "00:00")
        XCTAssertEqual(AgentGuardrails.formattedMinute(22 * 60), "22:00")
        XCTAssertEqual(AgentGuardrails.formattedMinute(7 * 60 + 5), "07:05")
        // Degenerate inputs clamp into the day rather than printing "24:30".
        XCTAssertEqual(AgentGuardrails.formattedMinute(24 * 60 + 30), "00:30")
    }
}
