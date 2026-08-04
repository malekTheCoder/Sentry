import XCTest
@testable import SentryKit

/// Unit tests for `CaffeinateArbitrator`'s pure surfaces (detection matcher,
/// attribution, and policy) — `SentryKit/Services/CaffeinateArbitrator.swift`.
///
/// **What is deliberately not covered here.** `liveProcessTable()` and
/// `terminate(pid:)` depend on the real, live system process table and
/// `kill()` — there is no libproc test double, and spawning real processes
/// from a unit test to exercise them would be flaky, slow, and would not
/// meaningfully test anything beyond "the OS's own `kill` syscall works."
/// Both are thin, explicitly-unverified seams between the pure logic tested
/// here and reality — same posture `ProcessCollectorTests` (if any existed)
/// would have to take toward `ProcessCollector`'s own libproc calls; only
/// `ProcessCollector.percent(...)`, the pure arithmetic, is actually tested
/// there, and only `CaffeinateArbitrator`'s pure matcher/policy are tested
/// here.
final class CaffeinateArbitratorTests: XCTestCase {

    // MARK: - Fixtures

    private func entry(
        pid: Int32,
        parentPID: Int32,
        name: String,
        arguments: [String] = []
    ) -> CaffeinateArbitrator.ProcessTableEntry {
        CaffeinateArbitrator.ProcessTableEntry(pid: pid, parentPID: parentPID, name: name, arguments: arguments)
    }

    // MARK: - matchesClaudeInvocationShape

    func testInvocationShapeMatchesExactDocumentedFlags() {
        XCTAssertTrue(CaffeinateArbitrator.matchesClaudeInvocationShape(["caffeinate", "-i", "-t", "300"]))
    }

    func testInvocationShapeIgnoresFlagOrder() {
        XCTAssertTrue(CaffeinateArbitrator.matchesClaudeInvocationShape(["caffeinate", "-t", "300", "-i"]))
    }

    func testInvocationShapeRejectsDifferentTimeout() {
        // A user's own `caffeinate -i -t 3600` must not be swept up —
        // see the doc comment on why the timeout is matched exactly.
        XCTAssertFalse(CaffeinateArbitrator.matchesClaudeInvocationShape(["caffeinate", "-i", "-t", "3600"]))
    }

    func testInvocationShapeRejectsMissingIFlag() {
        XCTAssertFalse(CaffeinateArbitrator.matchesClaudeInvocationShape(["caffeinate", "-t", "300"]))
    }

    func testInvocationShapeRejectsDanglingTFlag() {
        XCTAssertFalse(CaffeinateArbitrator.matchesClaudeInvocationShape(["caffeinate", "-i", "-t"]))
    }

    func testInvocationShapeRejectsEmptyArguments() {
        XCTAssertFalse(CaffeinateArbitrator.matchesClaudeInvocationShape([]))
    }

    // MARK: - ancestry

    func testAncestryWalksParentChain() {
        let table = [
            entry(pid: 100, parentPID: 1, name: "claude"),
            entry(pid: 200, parentPID: 100, name: "bash"),
            entry(pid: 300, parentPID: 200, name: "caffeinate", arguments: ["caffeinate", "-i", "-t", "300"]),
        ]
        let chain = CaffeinateArbitrator.ancestry(of: table[2], in: table)
        XCTAssertEqual(chain.map(\.name), ["bash", "claude"])
    }

    func testAncestryStopsAtMissingParent() {
        let table = [
            entry(pid: 300, parentPID: 999, name: "caffeinate"),
        ]
        XCTAssertEqual(CaffeinateArbitrator.ancestry(of: table[0], in: table), [])
    }

    func testAncestryDoesNotLoopOnCycle() {
        // Fabricated, pathological input: a table nothing in the real
        // process tree could produce. The pure function must still
        // terminate rather than trust its input is well-formed.
        let table = [
            entry(pid: 10, parentPID: 20, name: "a"),
            entry(pid: 20, parentPID: 10, name: "b"),
        ]
        let chain = CaffeinateArbitrator.ancestry(of: table[0], in: table)
        XCTAssertLessThanOrEqual(chain.count, CaffeinateArbitrator.maxAncestryDepth)
    }

    func testAncestryRespectsMaxDepth() {
        // A chain of "claude" far beyond the depth bound must not be found.
        var table: [CaffeinateArbitrator.ProcessTableEntry] = []
        var parent: Int32 = 1
        for pid in Int32(1)...Int32(10) {
            table.append(entry(pid: pid, parentPID: parent, name: pid == 1 ? "claude" : "hop\(pid)"))
            parent = pid
        }
        table.append(entry(pid: 11, parentPID: parent, name: "caffeinate"))
        let target = table.last!
        let chain = CaffeinateArbitrator.ancestry(of: target, in: table)
        XCTAssertEqual(chain.count, CaffeinateArbitrator.maxAncestryDepth)
        XCTAssertFalse(chain.contains { $0.name == "claude" })
    }

    // MARK: - matchExternalCaffeinates

    func testMatchesCaffeinateWithClaudeAncestor() {
        let table = [
            entry(pid: 1, parentPID: 0, name: "claude"),
            entry(pid: 2, parentPID: 1, name: "caffeinate", arguments: ["caffeinate", "-i", "-t", "300"]),
        ]
        let matches = CaffeinateArbitrator.matchExternalCaffeinates(in: table)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].pid, 2)
        XCTAssertEqual(matches[0].matchedViaAncestorNamed, "claude")
        XCTAssertTrue(matches[0].matchedInvocationShape)
    }

    func testMatchesCaffeinateWithClaudeAncestorEvenWithUnrelatedArgv() {
        // Ancestry alone is the strong signal — a different timeout
        // shouldn't suppress a real "claude" ancestor match.
        let table = [
            entry(pid: 1, parentPID: 0, name: "claude"),
            entry(pid: 2, parentPID: 1, name: "caffeinate", arguments: ["caffeinate", "-d"]),
        ]
        let matches = CaffeinateArbitrator.matchExternalCaffeinates(in: table)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].matchedViaAncestorNamed, "claude")
        XCTAssertFalse(matches[0].matchedInvocationShape)
    }

    func testMatchesCaffeinateByInvocationShapeAloneWithoutClaudeAncestor() {
        let table = [
            entry(pid: 1, parentPID: 0, name: "some-other-tool"),
            entry(pid: 2, parentPID: 1, name: "caffeinate", arguments: ["caffeinate", "-i", "-t", "300"]),
        ]
        let matches = CaffeinateArbitrator.matchExternalCaffeinates(in: table)
        XCTAssertEqual(matches.count, 1)
        XCTAssertNil(matches[0].matchedViaAncestorNamed)
        XCTAssertTrue(matches[0].matchedInvocationShape)
    }

    func testNoMatchWithoutEitherSignal() {
        let table = [
            entry(pid: 1, parentPID: 0, name: "some-other-tool"),
            entry(pid: 2, parentPID: 1, name: "caffeinate", arguments: ["caffeinate", "-t", "60"]),
        ]
        XCTAssertTrue(CaffeinateArbitrator.matchExternalCaffeinates(in: table).isEmpty)
    }

    func testNeverMatchesNonCaffeinateProcess() {
        // Conservative-by-construction: even a process literally named
        // "claude-helper" with `-i -t 300`-shaped arguments (nonsensical,
        // but a hostile/fabricated table could claim it) must never match —
        // only `caffeinate` is ever a candidate.
        let table = [
            entry(pid: 1, parentPID: 0, name: "claude"),
            entry(pid: 2, parentPID: 1, name: "not-caffeinate", arguments: ["-i", "-t", "300"]),
        ]
        XCTAssertTrue(CaffeinateArbitrator.matchExternalCaffeinates(in: table).isEmpty)
    }

    func testNameMatchIsCaseInsensitive() {
        let table = [
            entry(pid: 1, parentPID: 0, name: "Claude"),
            entry(pid: 2, parentPID: 1, name: "Caffeinate", arguments: ["Caffeinate", "-i", "-t", "300"]),
        ]
        let matches = CaffeinateArbitrator.matchExternalCaffeinates(in: table)
        XCTAssertEqual(matches.count, 1)
    }

    func testUnrelatedCaffeinateIsIgnored() {
        // A user's own manually-started `caffeinate -i -t 3600` with no
        // Claude ancestor at all — the exact case this heuristic must leave
        // alone.
        let table = [
            entry(pid: 1, parentPID: 0, name: "bash"),
            entry(pid: 2, parentPID: 1, name: "caffeinate", arguments: ["caffeinate", "-i", "-t", "3600"]),
        ]
        XCTAssertTrue(CaffeinateArbitrator.matchExternalCaffeinates(in: table).isEmpty)
    }

    // MARK: - attribute

    @MainActor
    func testAttributesToSoleActiveClaudeSession() {
        let match = CaffeinateArbitrator.ExternalCaffeinateMatch(
            pid: 2, parentPID: 1, arguments: ["caffeinate", "-i", "-t", "300"],
            matchedViaAncestorNamed: "claude", matchedInvocationShape: true
        )
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "Claude Code", tool: .getSystemSnapshot)
        let sessions = registry.activeSessions()

        let attributed = CaffeinateArbitrator.attribute(matches: [match], sessions: sessions)
        XCTAssertEqual(attributed.count, 1)
        XCTAssertEqual(attributed[0].clientName, "Claude Code")
    }

    @MainActor
    func testAttributionIsNilWhenNoClaudeSessionActive() {
        let match = CaffeinateArbitrator.ExternalCaffeinateMatch(
            pid: 2, parentPID: 1, arguments: [], matchedViaAncestorNamed: nil, matchedInvocationShape: true
        )
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "Cursor", tool: .getSystemSnapshot)

        let attributed = CaffeinateArbitrator.attribute(matches: [match], sessions: registry.activeSessions())
        XCTAssertEqual(attributed.count, 1)
        XCTAssertNil(attributed[0].clientName)
    }

    @MainActor
    func testAttributionIsNilWhenMultipleClaudeSessionsActive() {
        // Ambiguous — must not guess which one owns it.
        let match = CaffeinateArbitrator.ExternalCaffeinateMatch(
            pid: 2, parentPID: 1, arguments: [], matchedViaAncestorNamed: nil, matchedInvocationShape: true
        )
        let registry = AgentSessionRegistry()
        registry.recordCall(clientName: "Claude Code", tool: .getSystemSnapshot)
        registry.recordCall(clientName: "claude-code-cli", tool: .getSystemSnapshot)

        let attributed = CaffeinateArbitrator.attribute(matches: [match], sessions: registry.activeSessions())
        XCTAssertNil(attributed[0].clientName)
    }

    // MARK: - shouldEnforce (policy)

    private var gmtCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }()

    private func context(
        batteryPercent: Double? = nil,
        isPluggedIn: Bool? = nil,
        thermalPressure: ThermalStats.PressureLevel? = nil
    ) -> AgentGuardrails.PowerContext {
        AgentGuardrails.PowerContext(
            batteryPercent: batteryPercent,
            isPluggedIn: isPluggedIn,
            thermalPressure: thermalPressure,
            date: gmtCalendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 12))!,
            calendar: gmtCalendar
        )
    }

    func testEnforcesWhenToggleOnAndGuardrailsWouldRevoke() {
        let settings = AgentGuardrailSettings(thermalAutoRevokeEnabled: true, enforceAgainstExternalCaffeinate: true)
        XCTAssertTrue(CaffeinateArbitrator.shouldEnforce(settings: settings, context: context(thermalPressure: .critical)))
    }

    func testDoesNotEnforceWhenToggleOff() {
        let settings = AgentGuardrailSettings(thermalAutoRevokeEnabled: true, enforceAgainstExternalCaffeinate: false)
        XCTAssertFalse(CaffeinateArbitrator.shouldEnforce(settings: settings, context: context(thermalPressure: .critical)))
    }

    func testDoesNotEnforceWhenGuardrailsWouldNotRevoke() {
        // Toggle on, but nothing on the power/thermal side warrants it.
        let settings = AgentGuardrailSettings(enforceAgainstExternalCaffeinate: true)
        XCTAssertFalse(CaffeinateArbitrator.shouldEnforce(settings: settings, context: context()))
    }

    func testDoesNotEnforceWhenUnderlyingGuardrailItselfDisabled() {
        // Thermal pressure is critical, but the thermal guardrail that
        // would revoke on it is off — so there is nothing for this policy
        // to piggyback on either.
        let settings = AgentGuardrailSettings(thermalAutoRevokeEnabled: false, enforceAgainstExternalCaffeinate: true)
        XCTAssertFalse(CaffeinateArbitrator.shouldEnforce(settings: settings, context: context(thermalPressure: .critical)))
    }

    func testEnforcesUnderQuietHours() {
        let quietContext = AgentGuardrails.PowerContext(
            date: gmtCalendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23))!,
            calendar: gmtCalendar
        )
        let settings = AgentGuardrailSettings(
            quietHoursEnabled: true,
            quietHoursStartMinute: 22 * 60,
            quietHoursEndMinute: 7 * 60,
            enforceAgainstExternalCaffeinate: true
        )
        XCTAssertTrue(CaffeinateArbitrator.shouldEnforce(settings: settings, context: quietContext))
    }

    func testEnforcesWhenKillSwitchEngaged() {
        // `autoRevocationReason` treats the kill switch as its own
        // revocation reason (see that method's doc comment) — this policy
        // piggybacks on it exactly like the other two conditions.
        let settings = AgentGuardrailSettings(killSwitchEngaged: true, enforceAgainstExternalCaffeinate: true)
        XCTAssertTrue(CaffeinateArbitrator.shouldEnforce(settings: settings, context: context()))
    }

    func testBatteryFloorAloneDoesNotTriggerEnforcement() {
        // `AgentGuardrails.autoRevocationReason` does not include the
        // battery floor among its revocation reasons (only kill switch,
        // quiet hours, and thermal auto-revoke do) — so this policy, which
        // piggybacks on that method, must not fire on battery alone either,
        // even with the floor breached and the toggle on.
        let settings = AgentGuardrailSettings(batteryFloorEnabled: true, batteryFloorPercent: 20, enforceAgainstExternalCaffeinate: true)
        XCTAssertFalse(CaffeinateArbitrator.shouldEnforce(settings: settings, context: context(batteryPercent: 10, isPluggedIn: false)))
    }

    // MARK: - Settings round-trip (AgentGuardrailSettings.enforceAgainstExternalCaffeinate)

    func testEnforceAgainstExternalCaffeinateDefaultsOn() {
        XCTAssertTrue(AgentGuardrailSettings().enforceAgainstExternalCaffeinate)
    }

    func testEnforceAgainstExternalCaffeinateRoundTripsThroughAppSettings() throws {
        var settings = AppSettings()
        settings.agentGuardrails.enforceAgainstExternalCaffeinate = false

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.agentGuardrails.enforceAgainstExternalCaffeinate)
        XCTAssertEqual(decoded.agentGuardrails, settings.agentGuardrails)
    }

    func testEnforceAgainstExternalCaffeinateUpgradesFromJSONMissingTheKey() throws {
        // A settings block persisted before this field existed — must
        // upgrade to the shipped default (on), not a zeroed-out false.
        let decoded = try JSONDecoder().decode(AgentGuardrailSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.enforceAgainstExternalCaffeinate)
    }
}
