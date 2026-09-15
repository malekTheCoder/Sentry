import XCTest
@testable import Sentry
@testable import SentryKit

/// Conditional keep-awake — the five release rules in the sleep card's
/// "For" menu — arming and releasing on an ordinary
/// `PowerControlService`, with nothing to unlock first.
///
/// **This file replaces `ConditionalKeepAwakeGateTests`, and it is the
/// proof that the feature opened rather than merely stopped being
/// advertised.** That file pinned a paywall in two layers: the service
/// refused every conditional arm through a
/// `conditionalKeepAwakeAuthorized` closure and threw
/// `.conditionalKeepAwakeLocked`, and the card filtered the five
/// conditional triggers out of its menu through
/// `SleepTriggerOption.visibleOptions(isUnlocked:)`, replacing them with a
/// count-only locked row. Both layers are deleted — so the failure mode
/// worth testing is now the inverse one: an arm that quietly does nothing,
/// or a menu that quietly still withholds. Every test below asserts a
/// positive outcome (armed, released, offered), because "no longer
/// refused" is only interesting if the thing actually works.
///
/// Isolated `UserDefaults` suite per test, cleaned up in `tearDown()`,
/// exactly as `PowerControlServiceTests` does.
@MainActor
final class ConditionalKeepAwakeTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeTestDefaults(_ name: String) -> UserDefaults {
        let suiteName = "dev.malekswilam.sentry.tests.ConditionalKeepAwakeTests.\(name).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func snapshot(batteryPercent: Double? = nil) -> SystemSnapshot {
        SystemSnapshot(
            deviceID: "test-device",
            battery: batteryPercent.map { BatteryStats(chargePercent: $0, isCharging: false, isPluggedIn: false) }
        )
    }

    /// Every `ReleaseCondition` shape, including `.whileAppRunning` — no UI
    /// arms that one today, but the service is the layer that must accept
    /// the whole enum, not just what the card offers.
    private let allConditions: [ReleaseCondition] = [
        .batteryBelowPercent(20),
        .cpuAbovePercent(80, for: 300),
        .whileAppRunning(bundleIdentifier: "com.example.app"),
        .whileProcessRunning(name: "claude"),
        .whileDownloadActive(idleTimeout: 8),
        .scheduledWindow(weekdays: Set(1...7), startMinute: 0, endMinute: 1440)
    ]

    // MARK: - Arming actually arms

    /// The load-bearing test. Every condition shape arms on a
    /// default-constructed service and leaves a live, open-ended hold —
    /// `expiresAt: nil`, because a conditional hold ends on its condition,
    /// not a clock. Under the gate, every one of these threw.
    func testEveryConditionArmsOnAPlainServiceAndHoldsTheAssertion() throws {
        for condition in allConditions {
            let service = PowerControlService(defaults: makeTestDefaults("arms"))
            defer { service.releaseAssertion() }

            try service.startConditionalAssertion(
                mode: .systemOnly, condition: condition, reason: "armed for \(condition)"
            )

            XCTAssertEqual(
                service.state,
                .active(mode: .systemOnly, expiresAt: nil, reason: "armed for \(condition)"),
                "\(condition) must arm and hold — nothing may refuse it"
            )
        }
    }

    /// Arming is not enough on its own: an armed condition that is never
    /// evaluated would be a hold that never ends. This drives the real
    /// evaluation path — the condition stays unmet, then becomes met, and
    /// the hold drops by itself.
    func testAnArmedConditionIsEvaluatedAndReleasesTheHoldWhenItFires() throws {
        let service = PowerControlService(defaults: makeTestDefaults("releases"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "until battery is low"
        )

        service.evaluate(snapshot(batteryPercent: 55))
        XCTAssertNotEqual(service.state, .inactive, "55% is above the 20% floor — the hold must survive")

        service.evaluate(snapshot(batteryPercent: 10))
        XCTAssertEqual(service.state, .inactive, "the condition fired, so the hold must end on its own")
    }

    /// A conditional arm replaces a running timed hold, the same way any
    /// other arm does. Under the gate this pair was a *refusal* test — the
    /// denied arm had to leave the timed hold standing. The gate is gone,
    /// so the ordinary one-hold-per-slot behavior applies.
    func testAConditionalArmReplacesARunningTimedHold() throws {
        let service = PowerControlService(defaults: makeTestDefaults("replaces"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 3600, reason: "timed")
        try service.startConditionalAssertion(
            mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "conditional"
        )

        guard case .active(_, let expiresAt, let reason) = service.state else {
            return XCTFail("the conditional hold must be the live one")
        }
        XCTAssertEqual(reason, "conditional")
        XCTAssertNil(expiresAt, "a conditional hold is open-ended, not timed")
    }

    /// Timed, indefinite, adjust and release are unchanged — they were
    /// never gated, and the gate's removal must not have disturbed them.
    func testTimedIndefiniteAdjustAndReleaseAllStillWork() throws {
        let service = PowerControlService(defaults: makeTestDefaults("freePaths"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "timed")
        guard case .active(_, let expiresAt, _) = service.state, expiresAt != nil else {
            return XCTFail("a plain timed keep-awake must arm")
        }
        try service.adjustAssertion(bySeconds: 300)
        XCTAssertNotEqual(service.state, .inactive)

        service.releaseAssertion()
        try service.startAssertion(mode: .systemOnly, duration: nil, reason: "indefinite")
        XCTAssertEqual(service.state, .active(mode: .systemOnly, expiresAt: nil, reason: "indefinite"))

        service.releaseAssertion()
        XCTAssertEqual(service.state, .inactive)
    }

    /// Wake used to re-adjudicate a conditional hold against the
    /// entitlement and drop it if the license had lapsed while the Mac
    /// slept. Nothing re-adjudicates now, so an armed conditional hold must
    /// come back from sleep exactly as it went in.
    func testAConditionalHoldSurvivesAWake() throws {
        let defaults = makeTestDefaults("wake")
        let service = PowerControlService(defaults: defaults)
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(
            mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "armed before sleep"
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil
        )
        let resumed = expectation(description: "wake reconciliation ran")
        DispatchQueue.main.async { resumed.fulfill() }
        wait(for: [resumed], timeout: 2)

        XCTAssertEqual(
            service.state,
            .active(mode: .systemOnly, expiresAt: nil, reason: "armed before sleep"),
            "wake must not drop a hold the user is still asking for"
        )
    }

    // MARK: - The menu offers all of them

    /// **The UI half of the proof.** `visibleOptions(isUnlocked:)` used to
    /// filter the five conditional triggers out; the card now renders
    /// `allOptions` directly, so this asserts that list is complete —
    /// including all five that used to be withheld, by name.
    func testTheTriggerMenuOffersEveryConditionalReleaseRule() {
        let ids = SleepTriggerOption.allOptions.map(\.id)

        for withheldID in ["battery", "cpu", "process", "download", "schedule"] {
            XCTAssertTrue(
                ids.contains(withheldID),
                "“\(withheldID)” was one of the five withheld triggers and must be in the menu"
            )
        }
        XCTAssertEqual(
            SleepTriggerOption.allOptions.filter(\.isConditional).count, 5,
            "all five conditional release rules must be offered"
        )
        XCTAssertEqual(
            ids,
            ["indefinite", "fixed-900", "fixed-1800", "fixed-3600", "fixed-7200",
             "fixed-14400", "fixed-28800", "until-time",
             "battery", "cpu", "process", "download", "schedule"],
            "the full menu, in declared order"
        )
    }

    /// `isConditional` and `releaseCondition(...)` are two spellings of the
    /// same boundary. It no longer decides who may pick what — it decides
    /// whether a selection needs a threshold control — but a disagreement
    /// would still mean a trigger that looks armable and arms nothing.
    func testIsConditionalAgreesWithTheReleaseConditionMapping() {
        for option in SleepTriggerOption.allOptions {
            let condition = option.releaseCondition(
                batteryThreshold: 20,
                cpuThreshold: 80,
                cpuSustainedFor: 300,
                processName: "claude",
                downloadIdleTimeout: 8,
                schedule: .weeknights
            )
            XCTAssertEqual(
                option.isConditional,
                condition != nil,
                "\(option.id) disagrees between isConditional and releaseCondition"
            )
        }
    }

    /// End to end at the boundary the card actually crosses: every
    /// conditional trigger in the menu maps to a `ReleaseCondition` that
    /// the service then accepts. A menu entry that produced a condition
    /// `startConditionalAssertion` refused would be the exact
    /// looks-available-does-nothing failure this file exists to catch.
    func testEveryMenuTriggerArmsTheConditionItMapsTo() throws {
        for option in SleepTriggerOption.allOptions where option.isConditional {
            let condition = try XCTUnwrap(option.releaseCondition(
                batteryThreshold: 20,
                cpuThreshold: 80,
                cpuSustainedFor: 300,
                processName: "claude",
                downloadIdleTimeout: 8,
                schedule: .weeknights
            ))
            let service = PowerControlService(defaults: makeTestDefaults("menuArm"))
            defer { service.releaseAssertion() }

            try service.startConditionalAssertion(
                mode: .systemOnly, condition: condition, reason: option.id
            )
            XCTAssertNotEqual(
                service.state, .inactive,
                "picking “\(option.id)” in the For menu must actually hold the Mac awake"
            )
        }
    }
}
