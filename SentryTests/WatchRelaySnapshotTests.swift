import XCTest
@testable import SentryKit

/// Covers the two things `WatchRelaySnapshot` has to get right that nothing
/// else can check: that a payload survives a version mismatch in **both**
/// directions, and that `WatchRelayPolicy` still refuses to spend the
/// complication's update budget on the metrics added for the redesigned
/// watch app.
///
/// **Why these live in `SentryTests` (macOS-hosted) at all.** The types
/// under test are in `SentryKit`, which this bundle already links, and they
/// are pure Foundation with no WatchConnectivity dependency — so the version-
/// compatibility contract between the iPhone app and the watch app is
/// checkable without an iOS or watchOS test target existing. That is also
/// why `WatchRelayPolicy` was moved out of `WatchRelayManager` (an
/// iOS-target-only type this bundle cannot link); see that file's doc
/// comment.
final class WatchRelaySnapshotTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFullyPopulated() -> WatchRelaySnapshot {
        WatchRelaySnapshot(
            deviceName: "Test Mac",
            lastSeen: reference,
            relayedAt: reference.addingTimeInterval(5),
            sourceIsDemoData: false,
            batteryPercent: 63.4,
            isCharging: true,
            isPluggedIn: true,
            thermalPressure: .fair,
            batteryIsReported: true,
            cpuPercent: 41.2,
            memoryUsedPercent: 77.5,
            memoryPressure: .warning,
            diskUsedPercent: 58,
            batteryTimeRemainingMinutes: 92,
            isThrottling: false,
            awakeIsActive: true,
            awakeExpiresAt: reference.addingTimeInterval(3600),
            awakeModeLabel: "System only",
            agentToolCallCount: 12,
            agentLastActivityAt: reference.addingTimeInterval(-300),
            agentRecentToolNames: ["get_snapshot", "keep_awake"],
            agentAccessPaused: true
        )
    }

    // MARK: Round trip

    func testEveryFieldSurvivesAJSONRoundTrip() throws {
        let original = makeFullyPopulated()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testWCSessionPayloadRoundTripsThroughTheDictionaryWrapper() throws {
        let original = makeFullyPopulated()
        let payload = try XCTUnwrap(original.wcSessionPayload())
        let decoded = try XCTUnwrap(WatchRelaySnapshot.from(wcSessionPayload: payload))
        XCTAssertEqual(original, decoded)
    }

    func testAForeignDictionaryDecodesToNilRatherThanAnEmptySnapshot() {
        XCTAssertNil(WatchRelaySnapshot.from(wcSessionPayload: ["someOtherKey": Data()]))
    }

    // MARK: Old phone -> new watch

    /// The exact key set the first shipping build relayed. Written as a
    /// literal rather than generated from the current type on purpose: a
    /// generated fixture would silently follow any future change to the
    /// struct and stop testing the thing it exists to test.
    private var version1PayloadJSON: String {
        """
        {
          "deviceName": "Old Phone Mac",
          "lastSeen": 723600000,
          "relayedAt": 723600005,
          "sourceIsDemoData": false,
          "batteryPercent": 55.5,
          "isCharging": false,
          "isPluggedIn": false,
          "thermalPressure": "nominal"
        }
        """
    }

    func testAVersion1PayloadDecodesWithEveryLaterFieldNil() throws {
        let data = try XCTUnwrap(version1PayloadJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(WatchRelaySnapshot.self, from: data)

        XCTAssertEqual(decoded.deviceName, "Old Phone Mac")
        XCTAssertEqual(decoded.batteryPercent, 55.5)
        XCTAssertEqual(decoded.thermalPressure, .nominal)

        // Every field added after v1 must be absent, not zero — this is the
        // assertion that keeps "the Mac didn't report it" distinguishable
        // from "the Mac reported nothing happening."
        XCTAssertNil(decoded.batteryIsReported)
        XCTAssertNil(decoded.cpuPercent)
        XCTAssertNil(decoded.memoryUsedPercent)
        XCTAssertNil(decoded.memoryPressure)
        XCTAssertNil(decoded.diskUsedPercent)
        XCTAssertNil(decoded.batteryTimeRemainingMinutes)
        XCTAssertNil(decoded.isThrottling)
        XCTAssertNil(decoded.awakeIsActive)
        XCTAssertNil(decoded.awakeExpiresAt)
        XCTAssertNil(decoded.awakeModeLabel)
        XCTAssertNil(decoded.agentToolCallCount)
        XCTAssertNil(decoded.agentLastActivityAt)
        XCTAssertNil(decoded.agentRecentToolNames)
        XCTAssertNil(decoded.agentAccessPaused)
    }

    /// The same "silence, not a claim" rule `testAbsentBatteryIsReportedStaysNilRatherThanBecomingFalse`
    /// asserts for `batteryIsReported` applies with more force here: this
    /// field gates whether `AgentActivityPage` draws a resume *button*, and
    /// a `nil` misread as `false` would just be inert (no button), but a
    /// `nil` misread as `true` would draw a control claiming the Mac is
    /// paused when a v1-era phone said nothing of the kind.
    func testAbsentAgentAccessPausedStaysNilRatherThanBecomingFalse() throws {
        let data = try XCTUnwrap(version1PayloadJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
        XCTAssertNil(decoded.agentAccessPaused)
        XCTAssertNotEqual(decoded.agentAccessPaused, false)
    }

    /// A v1 payload is missing `batteryIsReported`, which is exactly the case
    /// the watch must *not* read as "this Mac has no battery" — see that
    /// field's doc comment. Asserted here because the difference is invisible
    /// at the type level (both cases are `nil`) and lives entirely in how
    /// `OverviewPage` interprets it.
    func testAbsentBatteryIsReportedStaysNilRatherThanBecomingFalse() throws {
        let data = try XCTUnwrap(version1PayloadJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
        XCTAssertNil(decoded.batteryIsReported)
        XCTAssertNotEqual(decoded.batteryIsReported, false)
    }

    // MARK: New phone -> old watch

    /// Simulates a payload from a *future* build carrying keys this build has
    /// never heard of. `JSONDecoder` ignores unknown keys, so the known
    /// subset must decode intact — this is the direction that fails silently
    /// (a complication that just stops updating) if it ever breaks.
    func testUnknownFutureKeysAreIgnoredRatherThanFailingTheDecode() throws {
        let json = """
        {
          "deviceName": "Future Mac",
          "lastSeen": 723600000,
          "relayedAt": 723600005,
          "sourceIsDemoData": true,
          "batteryPercent": 12,
          "isCharging": false,
          "isPluggedIn": false,
          "thermalPressure": "serious",
          "cpuPercent": 90,
          "someFieldInventedNextYear": {"nested": [1, 2, 3]},
          "anotherOne": "hello"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
        XCTAssertEqual(decoded.deviceName, "Future Mac")
        XCTAssertEqual(decoded.cpuPercent, 90)
        XCTAssertTrue(decoded.sourceIsDemoData)
    }

    /// The failure mode the hand-written decoder exists to prevent: a
    /// `String`-raw enum case added later would make synthesized `Codable`
    /// throw, losing battery, freshness *and* the demo-data disclosure over
    /// one unfamiliar word.
    func testAnUnrecognisedThermalTierDegradesToUnknownInsteadOfThrowing() throws {
        let json = """
        {
          "deviceName": "Future Mac",
          "lastSeen": 723600000,
          "relayedAt": 723600005,
          "sourceIsDemoData": true,
          "batteryPercent": 44,
          "isCharging": false,
          "isPluggedIn": false,
          "thermalPressure": "apocalyptic",
          "memoryPressure": "spicy"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
        XCTAssertEqual(decoded.thermalPressure, .unknown)
        XCTAssertEqual(decoded.memoryPressure, .unknown)
        // The whole rest of the payload survived, which is the point.
        XCTAssertEqual(decoded.batteryPercent, 44)
        XCTAssertTrue(decoded.sourceIsDemoData)
    }

    /// `.unknown` ("reported a tier we can't name") and `nil` ("reported no
    /// tier at all") are rendered differently by `OverviewPage`, so they must
    /// decode differently too.
    func testAbsentMemoryPressureIsNilNotUnknown() throws {
        let data = try XCTUnwrap(version1PayloadJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
        XCTAssertNil(decoded.memoryPressure)
    }

    // MARK: Strictness of the v1 core

    /// The v1 keys are decoded strictly on purpose: a message missing
    /// `batteryPercent` is not a Mac with an unknown battery, it is not one
    /// of ours. Both call sites funnel a decode failure into the same honest
    /// "no data yet" state.
    func testAPayloadMissingAVersion1KeyFailsToDecode() throws {
        let json = """
        {
          "deviceName": "Broken",
          "lastSeen": 723600000,
          "relayedAt": 723600005,
          "sourceIsDemoData": false,
          "isCharging": false,
          "isPluggedIn": false,
          "thermalPressure": "nominal"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(WatchRelaySnapshot.self, from: data))
    }

    // MARK: showsBattery (ComplicationView.swift's / OverviewPage's battery/CPU swap)

    /// `batteryIsReported == true` is the ordinary case: a laptop that
    /// genuinely reported a battery.
    func testShowsBatteryIsTrueWhenBatteryIsReportedTrue() {
        var snapshot = makeFullyPopulated()
        snapshot.batteryIsReported = true
        XCTAssertTrue(snapshot.showsBattery)
    }

    /// `batteryIsReported == false` is a Mac mini/Studio/Pro that explicitly
    /// reported no battery — this is the case the headline metric must swap
    /// away from `batteryPercent` for, since `WatchRelayManager` fills that
    /// field with a fake `0` on exactly these Macs.
    func testShowsBatteryIsFalseWhenBatteryIsReportedFalse() {
        var snapshot = makeFullyPopulated()
        snapshot.batteryIsReported = false
        XCTAssertFalse(snapshot.showsBattery)
    }

    /// `nil` — a phone predating the field — must default to `true`, not
    /// `false`: it is silence, not a claim that there is no battery. This is
    /// the same assertion `testAbsentBatteryIsReportedStaysNilRatherThanBecomingFalse`
    /// makes about the raw field; this one covers the derived property every
    /// rendering call site actually reads.
    func testShowsBatteryDefaultsToTrueWhenBatteryIsReportedIsNil() {
        var snapshot = makeFullyPopulated()
        snapshot.batteryIsReported = nil
        XCTAssertTrue(snapshot.showsBattery)
    }

    // MARK: Encoded size

    /// The payload crosses `WCSession`, which is not a place for a full
    /// `SystemSnapshot`. This is a regression guard with a deliberately loose
    /// bound, not a byte-exact assertion: it exists to catch somebody
    /// relaying an array of per-core percentages or a battery-history buffer,
    /// not to make an innocuous field addition fail the suite.
    func testAFullyPopulatedPayloadStaysSmall() throws {
        let data = try JSONEncoder().encode(makeFullyPopulated())
        XCTAssertLessThan(data.count, 1024, "Encoded relay payload grew past 1 KB: \(data.count) bytes")
    }

    // MARK: - themeID / resolvedTheme (the Watch redesign's one new wire
    // field: the watch renders in the user's chosen palette, and an id is
    // what travels rather than a table of colours)

    func testAKnownThemeIDResolvesToThatPreset() {
        var snapshot = makeFullyPopulated()
        snapshot.themeID = Theme.nord.id
        XCTAssertEqual(snapshot.resolvedTheme.id, Theme.nord.id)
    }

    func testAnAbsentThemeIDFallsBackToTheDefaultTheme() {
        var snapshot = makeFullyPopulated()
        snapshot.themeID = nil
        XCTAssertEqual(snapshot.resolvedTheme.id, Theme.defaultTheme.id)
    }

    func testAnUnknownThemeIDFallsBackRatherThanApproximating() {
        // A custom, user-authored theme has no entry in `builtInPresets`, so
        // the watch has never been sent its colours. Falling back is the
        // honest outcome; rendering some other preset's palette because the
        // id "looks close" would be worse than the default.
        var snapshot = makeFullyPopulated()
        snapshot.themeID = "custom.something-the-watch-was-never-sent"
        XCTAssertEqual(snapshot.resolvedTheme.id, Theme.defaultTheme.id)
    }

    func testThemeIDSurvivesTheWCSessionRoundTrip() throws {
        var snapshot = makeFullyPopulated()
        snapshot.themeID = Theme.dracula.id
        let payload = try XCTUnwrap(snapshot.wcSessionPayload())
        let decoded = try XCTUnwrap(WatchRelaySnapshot.from(wcSessionPayload: payload))
        XCTAssertEqual(decoded.themeID, Theme.dracula.id)
    }

    func testEveryBuiltInPresetIDRoundTripsToItself() {
        // Guards the one way this design can silently break: an id renamed on
        // the Mac side while the watch keeps resolving the old string.
        for theme in Theme.builtInPresets {
            var snapshot = makeFullyPopulated()
            snapshot.themeID = theme.id
            XCTAssertEqual(
                snapshot.resolvedTheme.id, theme.id,
                "\(theme.id) must resolve to itself on the watch"
            )
        }
    }

    // MARK: - timelineRelevanceScore (verified-bug pass: the watch
    // complication never told Smart Stack when the Mac actually needed
    // attention — see `SentryWatchWidgetEntry.relevance`'s doc comment)

    private func relevanceSnapshot(
        thermal: ThermalPressureSummary = .nominal,
        memoryPressure: MemoryPressureSummary? = .normal,
        throttling: Bool? = false
    ) -> WatchRelaySnapshot {
        var snapshot = makeFullyPopulated()
        snapshot.thermalPressure = thermal
        snapshot.memoryPressure = memoryPressure
        snapshot.isThrottling = throttling
        return snapshot
    }

    func testANominalHealthyMacScoresZero() {
        let snapshot = relevanceSnapshot()
        XCTAssertEqual(snapshot.timelineRelevanceScore, 0, "a healthy Mac must not outrank whatever the user actually pinned")
    }

    func testCriticalThermalPressureScoresTheMaximum() {
        let snapshot = relevanceSnapshot(thermal: .critical)
        XCTAssertEqual(snapshot.timelineRelevanceScore, 100)
    }

    func testThrottlingOutranksMerelySeriousThermalPressure() {
        let throttling = relevanceSnapshot(thermal: .serious, throttling: true)
        let seriousOnly = relevanceSnapshot(thermal: .serious, throttling: false)
        XCTAssertGreaterThan(throttling.timelineRelevanceScore, seriousOnly.timelineRelevanceScore)
    }

    func testCriticalMemoryPressureAloneStillScoresAboveNominal() {
        let snapshot = relevanceSnapshot(memoryPressure: .critical)
        XCTAssertGreaterThan(snapshot.timelineRelevanceScore, 0)
    }

    func testTheWorseOfTwoSimultaneousProblemsWins() {
        // Fair thermal (25) alongside critical memory (80): the score must
        // reflect whichever signal is actually worse, not the last one
        // evaluated or a sum of the two.
        let snapshot = relevanceSnapshot(thermal: .fair, memoryPressure: .critical)
        XCTAssertEqual(snapshot.timelineRelevanceScore, 80)
    }

    func testUnknownTiersAreTreatedAsNoSignalRatherThanInflatingTheScore() {
        let snapshot = relevanceSnapshot(thermal: .unknown, memoryPressure: .unknown)
        XCTAssertEqual(snapshot.timelineRelevanceScore, 0, "an unrecognised tier from a newer phone must not be read as a problem")
    }
}

// MARK: - WatchRelayPolicy

final class WatchRelayPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        battery: Double = 50,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        thermal: ThermalPressureSummary = .nominal,
        cpu: Double? = 10,
        memory: Double? = 50,
        memoryPressure: MemoryPressureSummary? = .normal,
        disk: Double? = 40,
        throttling: Bool? = false,
        awakeIsActive: Bool? = false,
        awakeExpiresAt: Date? = nil,
        agentAccessPaused: Bool? = false,
        agentToolCallCount: Int? = nil
    ) -> WatchRelaySnapshot {
        WatchRelaySnapshot(
            deviceName: "Test Mac",
            lastSeen: now,
            relayedAt: now,
            sourceIsDemoData: false,
            batteryPercent: battery,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            thermalPressure: thermal,
            batteryIsReported: true,
            cpuPercent: cpu,
            memoryUsedPercent: memory,
            memoryPressure: memoryPressure,
            diskUsedPercent: disk,
            isThrottling: throttling,
            awakeIsActive: awakeIsActive,
            awakeExpiresAt: awakeExpiresAt,
            agentToolCallCount: agentToolCallCount,
            agentAccessPaused: agentAccessPaused
        )
    }

    // MARK: The two guards

    func testTheFirstRelayOfARunAlwaysGoesOutImmediately() {
        XCTAssertTrue(
            WatchRelayPolicy.shouldRelay(
                previous: nil,
                next: snapshot(),
                lastRelayedAt: nil,
                now: now
            )
        )
    }

    func testTheHeartbeatFiresWithNoChangeAtAll() {
        let identical = snapshot()
        XCTAssertTrue(
            WatchRelayPolicy.shouldRelay(
                previous: identical,
                next: identical,
                lastRelayedAt: now.addingTimeInterval(-WatchRelayPolicy.minimumRelayInterval),
                now: now
            )
        )
    }

    func testASignificantChangeInsideTheCooldownIsHeldBack() {
        XCTAssertFalse(
            WatchRelayPolicy.shouldRelay(
                previous: snapshot(isCharging: false),
                next: snapshot(isCharging: true),
                lastRelayedAt: now.addingTimeInterval(-(WatchRelayPolicy.significantChangeCooldown - 1)),
                now: now
            )
        )
    }

    func testASignificantChangePastTheCooldownRelaysEarly() {
        XCTAssertTrue(
            WatchRelayPolicy.shouldRelay(
                previous: snapshot(isCharging: false),
                next: snapshot(isCharging: true),
                lastRelayedAt: now.addingTimeInterval(-WatchRelayPolicy.significantChangeCooldown),
                now: now
            )
        )
    }

    // MARK: What counts as significant

    func testDiscreteUserVisibleTransitionsCountAsSignificant() {
        let base = snapshot()
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(isCharging: true)))
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(isPluggedIn: true)))
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(thermal: .serious)))
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(throttling: true)))
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(memoryPressure: .critical)))
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(awakeIsActive: true)))
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(battery: 51)))
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(agentAccessPaused: true)))
    }

    /// `agentToolCallCount` going from unreported to reported at all — e.g.
    /// the composition-root hook on `StatsCoordinator.agentActivitySummary`
    /// landing, or the very first tool call of a run — is the one agent-
    /// activity transition worth an early relay: a user who just triggered
    /// the first call on a freshly-hooked-up Mac shouldn't wait out the
    /// heartbeat for `AgentActivityPage` to leave its "not reported" state.
    func testAgentToolCallCountBecomingReportedIsSignificant() {
        let base = snapshot(agentToolCallCount: nil)
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(agentToolCallCount: 0)))
    }

    /// The reverse transition — a relaunch that hasn't seen a call yet —
    /// is equally rare and equally worth an early relay.
    func testAgentToolCallCountBecomingUnreportedIsSignificant() {
        let base = snapshot(agentToolCallCount: 5)
        XCTAssertTrue(WatchRelayPolicy.isSignificantChange(from: base, to: snapshot(agentToolCallCount: nil)))
    }

    /// **The load-bearing negative for this field.** Once reported, the
    /// count itself must NOT be compared by value — tool calls arrive in
    /// bursts of dozens per minute from a chatty MCP client, and comparing
    /// the raw count would relay on every single call, collapsing the policy
    /// to "always relay" for exactly the reason
    /// `testTheContinuousMetricsDoNotTriggerARelayOfTheirOwn` guards against
    /// for CPU/memory/disk.
    func testAgentToolCallCountChangingValueOnceReportedIsNotSignificant() {
        let base = snapshot(agentToolCallCount: 1)
        let busy = snapshot(agentToolCallCount: 47)
        XCTAssertFalse(WatchRelayPolicy.isSignificantChange(from: base, to: busy))
    }

    /// **The load-bearing assertion of this whole file.** The redesigned
    /// watch app renders CPU, memory and disk, and the tempting next step is
    /// to relay whenever they move. They move every tick, so that would
    /// collapse the policy to "relay every 30 seconds forever" and exhaust
    /// the complication's background-update budget — leaving the watch *less*
    /// current than a paced relay, which is the exact failure
    /// `WatchRelayManager`'s doc comment describes.
    func testTheContinuousMetricsDoNotTriggerARelayOfTheirOwn() {
        let base = snapshot(cpu: 5, memory: 40, disk: 30)
        let busy = snapshot(cpu: 98, memory: 91, disk: 88)
        XCTAssertFalse(WatchRelayPolicy.isSignificantChange(from: base, to: busy))
    }

    /// The keep-awake expiry is relayed as an absolute deadline precisely so
    /// the watch can count down from its own clock without a fresh relay —
    /// so an expiry change on its own must not spend budget.
    func testAnExtendedKeepAwakeExpiryAloneDoesNotTriggerARelay() {
        let base = snapshot(awakeIsActive: true, awakeExpiresAt: now.addingTimeInterval(600))
        let extended = snapshot(awakeIsActive: true, awakeExpiresAt: now.addingTimeInterval(2400))
        XCTAssertFalse(WatchRelayPolicy.isSignificantChange(from: base, to: extended))
    }

    /// Sub-whole-point battery drift is noise; the comparison is deliberately
    /// at the resolution the watch actually renders.
    func testSubPointBatteryDriftIsNotSignificant() {
        XCTAssertFalse(
            WatchRelayPolicy.isSignificantChange(from: snapshot(battery: 50.1), to: snapshot(battery: 50.4))
        )
    }

    /// An old phone sends `nil` for every post-v1 field, so those comparisons
    /// must be inert rather than a source of phantom "changes".
    func testAVersion1StyleSnapshotComparedToItselfIsNotSignificant() {
        let v1Style = WatchRelaySnapshot(
            deviceName: "Old",
            lastSeen: now,
            relayedAt: now,
            sourceIsDemoData: false,
            batteryPercent: 50,
            isCharging: false,
            isPluggedIn: false,
            thermalPressure: .nominal
        )
        XCTAssertFalse(WatchRelayPolicy.isSignificantChange(from: v1Style, to: v1Style))
    }
}
