import XCTest
@testable import SentryKit

/// Covers the pure attribution arithmetic in `AgentSessionReport`
/// (SentryKit/Services/AgentSessionReport.swift) against fabricated
/// fixtures — no real `HistoryStore`/`PowerControlService` involved, same
/// isolation reasoning as `HistoryStoreTests` gives for writing rollup rows
/// directly — plus `AgentSessionIdentity`'s wire-format round trip.
final class AgentSessionReportTests: XCTestCase {

    private func date(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }

    // MARK: - AgentSessionIdentity wire format

    func testIdentityEncodeParseRoundTrips() {
        let sessionID = UUID().uuidString
        let wire = AgentSessionIdentity.encode(clientName: "Claude Code", sessionID: sessionID)
        let parsed = AgentSessionIdentity.parse(wire)
        XCTAssertEqual(parsed.clientName, "Claude Code")
        XCTAssertEqual(parsed.sessionID, sessionID)
    }

    func testIdentityParsePlainNameHasNoSession() {
        let parsed = AgentSessionIdentity.parse("Cursor")
        XCTAssertEqual(parsed.clientName, "Cursor")
        XCTAssertNil(parsed.sessionID)
    }

    func testIdentityParseRejectsNonUUIDAfterSeparator() {
        // A client embedding the separator in its self-reported name must
        // not be able to make an arbitrary string masquerade as a session
        // ID — only a well-formed UUID after the last separator counts.
        let wire = "Sneaky\u{1F}not-a-uuid"
        let parsed = AgentSessionIdentity.parse(wire)
        XCTAssertEqual(parsed.clientName, wire)
        XCTAssertNil(parsed.sessionID)
    }

    func testIdentityParseUsesLastSeparatorWhenNameContainsOne() {
        let sessionID = UUID().uuidString
        let wire = AgentSessionIdentity.encode(clientName: "Weird\u{1F}Name", sessionID: sessionID)
        let parsed = AgentSessionIdentity.parse(wire)
        XCTAssertEqual(parsed.clientName, "Weird\u{1F}Name")
        XCTAssertEqual(parsed.sessionID, sessionID)
    }

    // MARK: - Keep-awake attribution arithmetic

    func testAwakeSecondsClipsHoldToWindowAndFiltersByOwner() {
        let window = date(1_000)...date(2_000)
        let holds = [
            // Starts before the window, ends inside: only the in-window
            // part (1_000 → 1_200 = 200s) may count.
            AgentAwakeHold(owner: "s1", start: date(500), end: date(1_200)),
            // Fully inside: 300s.
            AgentAwakeHold(owner: "s1", start: date(1_400), end: date(1_700)),
            // Someone else's hold — excluded entirely.
            AgentAwakeHold(owner: "s2", start: date(1_000), end: date(2_000)),
            // Un-owned (user-initiated) hold — also excluded for "s1".
            AgentAwakeHold(owner: nil, start: date(1_000), end: date(2_000)),
        ]

        XCTAssertEqual(AgentSessionReport.awakeSeconds(holds: holds, owner: "s1", window: window), 500, accuracy: 0.001)
        XCTAssertEqual(AgentSessionReport.awakeSeconds(holds: holds, owner: "s2", window: window), 1_000, accuracy: 0.001)
    }

    func testAwakeSecondsClampsOpenEndedHoldToWindowEnd() {
        // An open hold demonstrably ran to the window's end; claiming more
        // would be fabrication.
        let window = date(1_000)...date(2_000)
        let holds = [AgentAwakeHold(owner: "s1", start: date(1_900), end: nil)]
        XCTAssertEqual(AgentSessionReport.awakeSeconds(holds: holds, owner: "s1", window: window), 100, accuracy: 0.001)
    }

    func testAwakeSecondsIgnoresHoldEntirelyOutsideWindow() {
        let window = date(1_000)...date(2_000)
        let holds = [AgentAwakeHold(owner: "s1", start: date(2_500), end: date(3_000))]
        XCTAssertEqual(AgentSessionReport.awakeSeconds(holds: holds, owner: "s1", window: window), 0)
    }

    // MARK: - Battery drain (machine-wide "during", never "caused by")

    func testBatteryPercentDrainedIsFirstMinusLast() {
        let samples = [
            (timestamp: date(1_000), value: 80.0),
            (timestamp: date(1_500), value: 74.0),
            (timestamp: date(2_000), value: 71.5),
        ]
        XCTAssertEqual(AgentSessionReport.batteryPercentDrained(samples: samples), 8.5)
    }

    func testBatteryPercentDrainedIsNegativeWhenCharging() {
        let samples = [
            (timestamp: date(1_000), value: 40.0),
            (timestamp: date(2_000), value: 55.0),
        ]
        XCTAssertEqual(AgentSessionReport.batteryPercentDrained(samples: samples), -15.0)
    }

    func testBatteryPercentDrainedNeedsAtLeastTwoSamples() {
        XCTAssertNil(AgentSessionReport.batteryPercentDrained(samples: []))
        XCTAssertNil(AgentSessionReport.batteryPercentDrained(samples: [(timestamp: date(1_000), value: 50.0)]))
    }

    // MARK: - Thermal elevation

    func testThermalElevationAccumulatesOnlyElevatedIntervals() {
        // pressure_level encoding per HistoryStore.pressureLevelCode:
        // 0 nominal, 1 fair, 2 serious, 3 critical — anything > 0 counts.
        let samples = [
            (timestamp: date(1_030), value: 0.0),  // 30s nominal
            (timestamp: date(1_060), value: 1.0),  // 30s elevated
            (timestamp: date(1_120), value: 2.0),  // 60s elevated
            (timestamp: date(1_150), value: 0.0),  // 30s nominal
        ]
        let result = AgentSessionReport.thermalElevation(samples: samples, windowStart: date(1_000))
        XCTAssertTrue(result.elevated)
        XCTAssertEqual(result.seconds, 90, accuracy: 0.001)
    }

    func testThermalElevationCapsGapAfterSamplingHole() {
        // One sample arriving after a long persistence gap must not claim
        // the whole gap was elevated — the per-sample interval is capped.
        let samples = [(timestamp: date(10_000), value: 3.0)]
        let result = AgentSessionReport.thermalElevation(samples: samples, windowStart: date(1_000))
        XCTAssertTrue(result.elevated)
        XCTAssertEqual(result.seconds, AgentSessionReport.maxSampleGapSeconds, accuracy: 0.001)
    }

    func testThermalElevationAllNominalReportsNotElevated() {
        let samples = [
            (timestamp: date(1_030), value: 0.0),
            (timestamp: date(1_060), value: 0.0),
        ]
        let result = AgentSessionReport.thermalElevation(samples: samples, windowStart: date(1_000))
        XCTAssertFalse(result.elevated)
        XCTAssertEqual(result.seconds, 0)
    }

    // MARK: - Full attribution

    func testAttributionCorrelatesEventsHoldsAndHistory() {
        let window = date(1_000)...date(2_000)
        let events = [
            AgentActivityEvent(timestamp: date(1_100), clientName: "Claude Code", tool: "keep_awake", sessionID: "s1", durationMs: 12, argsSummary: nil, outcome: .succeeded),
            AgentActivityEvent(timestamp: date(1_200), clientName: "Claude Code", tool: "get_system_snapshot", sessionID: "s1", durationMs: 3, argsSummary: nil, outcome: .succeeded),
            AgentActivityEvent(timestamp: date(1_900), clientName: "Claude Code", tool: "get_system_snapshot", sessionID: "s1", durationMs: 4, argsSummary: nil, outcome: .denied),
        ]
        let holds = [AgentAwakeHold(owner: "s1", start: date(1_100), end: date(1_600))]

        let attribution = AgentSessionReport.attribution(
            sessionID: "s1",
            clientName: "Claude Code",
            events: events,
            awakeHolds: holds,
            batterySamples: [(timestamp: date(1_050), value: 90.0), (timestamp: date(1_950), value: 84.0)],
            thermalPressureSamples: [(timestamp: date(1_100), value: 0.0), (timestamp: date(1_200), value: 2.0)],
            window: window
        )

        XCTAssertEqual(attribution.sessionStart, date(1_100))
        XCTAssertEqual(attribution.sessionEnd, date(1_900))
        XCTAssertEqual(attribution.callCount, 3)
        XCTAssertEqual(attribution.toolCallCounts, ["keep_awake": 1, "get_system_snapshot": 2])
        XCTAssertEqual(attribution.keepAwakeSecondsHeld, 500, accuracy: 0.001)
        XCTAssertEqual(attribution.batteryPercentDrained, 6.0)
        XCTAssertTrue(attribution.thermalPressureElevated)
        XCTAssertEqual(attribution.thermalPressureElevatedSeconds, 100, accuracy: 0.001)
    }

    func testAttributionWithNoEventsHasNilSessionSpan() {
        let attribution = AgentSessionReport.attribution(
            sessionID: "s1",
            clientName: "Claude Code",
            events: [],
            awakeHolds: [],
            batterySamples: [],
            thermalPressureSamples: [],
            window: date(1_000)...date(2_000)
        )
        XCTAssertNil(attribution.sessionStart)
        XCTAssertNil(attribution.sessionEnd)
        XCTAssertEqual(attribution.callCount, 0)
        XCTAssertNil(attribution.batteryPercentDrained)
        XCTAssertFalse(attribution.thermalPressureElevated)
    }

    // MARK: - Dashboard session grouping

    func testSessionsGroupsBySessionIDAndSortsMostRecentFirst() {
        let events = [
            AgentActivityEvent(timestamp: date(1_000), clientName: "Claude Code", tool: "keep_awake", sessionID: "s1"),
            AgentActivityEvent(timestamp: date(1_500), clientName: "Claude Code", tool: "release_awake", sessionID: "s1"),
            AgentActivityEvent(timestamp: date(1_800), clientName: "Cursor", tool: "get_system_snapshot", sessionID: "s2"),
        ]
        let holds = [AgentAwakeHold(owner: "s1", start: date(1_000), end: date(1_500))]

        let sessions = AgentSessionReport.sessions(from: events, awakeHolds: holds, now: date(2_000))

        XCTAssertEqual(sessions.map(\.id), ["s2", "s1"])
        XCTAssertEqual(sessions[1].clientName, "Claude Code")
        XCTAssertEqual(sessions[1].start, date(1_000))
        XCTAssertEqual(sessions[1].end, date(1_500))
        XCTAssertEqual(sessions[1].callCount, 2)
        XCTAssertEqual(sessions[1].toolCallCounts, ["keep_awake": 1, "release_awake": 1])
        XCTAssertEqual(sessions[1].awakeSecondsHeld, 500, accuracy: 0.001)
        XCTAssertEqual(sessions[0].awakeSecondsHeld, 0)
    }

    func testSessionsGroupsLegacyEventsByClientNameWithZeroAwakeTime() {
        // Pre-v5 rows carry no session — they group by client name under a
        // synthetic legacy key, and never claim awake time (the in-memory
        // ledger can't vouch for holds from before this app run).
        let events = [
            AgentActivityEvent(timestamp: date(1_000), clientName: "Old Client", tool: "keep_awake"),
            AgentActivityEvent(timestamp: date(1_100), clientName: "Old Client", tool: "release_awake"),
        ]
        // Even a same-named owner in the ledger must not attach to a legacy
        // group — owners are session IDs, not client names.
        let holds = [AgentAwakeHold(owner: "Old Client", start: date(1_000), end: date(1_100))]

        let sessions = AgentSessionReport.sessions(from: events, awakeHolds: holds, now: date(2_000))

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, AgentSessionReport.legacyGroupPrefix + "Old Client")
        XCTAssertEqual(sessions[0].clientName, "Old Client")
        XCTAssertEqual(sessions[0].callCount, 2)
        XCTAssertEqual(sessions[0].awakeSecondsHeld, 0)
    }
}

#if os(macOS)
/// The one non-pure seam feature 2 added: `PowerControlService`'s
/// awake-hold ledger. Uses real (immediately released) `IOPMAssertion`s,
/// same justification as `PowerControlServiceTests`' own type doc comment.
@MainActor
final class PowerControlAwakeLedgerTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeTestDefaults(_ name: String) -> UserDefaults {
        let suiteName = "dev.malekswilam.sentry.tests.PowerControlAwakeLedgerTests.\(name).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testStartWithOwnerOpensTaggedHoldAndReleaseClosesIt() throws {
        let service = PowerControlService(defaults: makeTestDefaults("taggedHold"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "ledger test", owner: "session-abc")
        XCTAssertEqual(service.awakeHolds.count, 1)
        XCTAssertEqual(service.awakeHolds[0].owner, "session-abc")
        XCTAssertNil(service.awakeHolds[0].end, "hold should stay open while the assertion is live")

        service.releaseAssertion()
        XCTAssertEqual(service.awakeHolds.count, 1)
        XCTAssertNotNil(service.awakeHolds[0].end)
    }

    func testReplacingAnAssertionClosesThePreviousHold() throws {
        let service = PowerControlService(defaults: makeTestDefaults("replaceHold"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "first", owner: "s1")
        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "second", owner: "s2")

        XCTAssertEqual(service.awakeHolds.count, 2)
        XCTAssertNotNil(service.awakeHolds[0].end, "replaced hold must be closed")
        XCTAssertEqual(service.awakeHolds[0].owner, "s1")
        XCTAssertNil(service.awakeHolds[1].end)
        XCTAssertEqual(service.awakeHolds[1].owner, "s2")
    }

    func testOwnerlessStartStillRecordsAHold() throws {
        // UI-initiated holds land in the ledger too (owner nil) — the
        // ledger is "who held the machine awake, and when," not an
        // agent-only log; `AgentSessionReport.awakeSeconds` filters by
        // owner at query time.
        let service = PowerControlService(defaults: makeTestDefaults("ownerless"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "user hold")
        XCTAssertEqual(service.awakeHolds.count, 1)
        XCTAssertNil(service.awakeHolds[0].owner)
    }
}
#endif
