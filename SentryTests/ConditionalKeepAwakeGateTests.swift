import XCTest
@testable import Sentry
@testable import SentryKit

/// The `ProFeature.conditionalKeepAwake` gate, both layers.
///
/// Service layer: `PowerControlService.conditionalKeepAwakeAuthorized` is the
/// arm-time choke point in `startAssertionInternal` — these tests drive it
/// through the same injected-closure seam `processProbe`/`downloadProbe`
/// already use, with an isolated `UserDefaults` suite per test exactly as
/// `PowerControlServiceTests` does. UI layer: the pure
/// `SleepTriggerOption` helpers (`visibleOptions`, `isConditional`,
/// `lockedOptionsMenuTitle`) that keep the locked "For" menu withheld rather
/// than obscured — pure functions on purpose, per
/// `SleepControlCardFormattingTests`' note on why card tests never arm a
/// real assertion.
///
/// What is deliberately asserted alongside the denials: everything that must
/// SURVIVE the lock. Timed/indefinite arming, adjusting, and every release
/// path are never gated — an escape hatch behind a paywall would be the
/// worst possible lapse behavior — and an already-armed conditional hold
/// keeps running *and keeps releasing on its condition* after the
/// entitlement flips off (see the closure's doc comment for the policy).
@MainActor
final class ConditionalKeepAwakeGateTests: XCTestCase {

    /// UserDefaults suite names created by `makeTestDefaults`, cleaned up in
    /// `tearDown()` so tests don't leave `~/Library/Preferences` plists
    /// behind across runs — same hygiene as `PowerControlServiceTests`.
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeTestDefaults(_ name: String) -> UserDefaults {
        let suiteName = "dev.malekswilam.sentry.tests.ConditionalKeepAwakeGateTests.\(name).\(UUID().uuidString)"
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
    /// arms that one today, but the service gate is the defense-in-depth
    /// layer and must cover the whole enum, not just what the card offers.
    private let allConditions: [ReleaseCondition] = [
        .batteryBelowPercent(20),
        .cpuAbovePercent(80, for: 300),
        .whileAppRunning(bundleIdentifier: "com.example.app"),
        .whileProcessRunning(name: "claude"),
        .whileDownloadActive(idleTimeout: 8),
        .scheduledWindow(weekdays: Set(1...7), startMinute: 0, endMinute: 1440)
    ]

    // MARK: - Locked: conditional arming is denied

    func testLockedArmingIsDeniedForEveryConditionWithTheLockedError() {
        let service = PowerControlService(defaults: makeTestDefaults("lockedDenies"))
        defer { service.releaseAssertion() }
        service.conditionalKeepAwakeAuthorized = { false }

        for condition in allConditions {
            XCTAssertThrowsError(
                try service.startConditionalAssertion(mode: .systemOnly, condition: condition, reason: "denied arm"),
                "locked arming must throw for \(condition)"
            ) { error in
                XCTAssertEqual(error as? PowerControlError, .conditionalKeepAwakeLocked)
            }
            XCTAssertEqual(service.state, .inactive, "a denied arm must not leave anything held for \(condition)")
        }
    }

    func testLockedDeniedArmDoesNotTearDownTheRunningHold() throws {
        // Pins the gate's position *before* `startAssertionInternal`'s
        // release-previous step: a locked user flipping "For" to a
        // conditional trigger over a live timed hold must get an error, not
        // an error plus a torn-down session.
        let service = PowerControlService(defaults: makeTestDefaults("lockedKeepsRunningHold"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 3600, reason: "timed hold survives")
        service.conditionalKeepAwakeAuthorized = { false }

        XCTAssertThrowsError(
            try service.startConditionalAssertion(mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "denied arm")
        )
        guard case .active(_, let expiresAt, let reason) = service.state else {
            return XCTFail("the running timed hold must survive a denied conditional arm")
        }
        XCTAssertEqual(reason, "timed hold survives")
        XCTAssertNotNil(expiresAt, "the survivor must still be the original timed hold, not a replacement")
    }

    // MARK: - Locked: everything free stays free

    func testTimedIndefiniteAndAdjustKeepWorkingWhileLocked() throws {
        let service = PowerControlService(defaults: makeTestDefaults("lockedFreePaths"))
        defer { service.releaseAssertion() }
        service.conditionalKeepAwakeAuthorized = { false }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "timed while locked")
        guard case .active(_, let expiresAt, _) = service.state, expiresAt != nil else {
            return XCTFail("a plain timed keep-awake must arm while locked")
        }
        try service.adjustAssertion(bySeconds: 300)
        XCTAssertNotEqual(service.state, .inactive, "adjusting a timed hold must work while locked")

        service.releaseAssertion()
        try service.startAssertion(mode: .systemOnly, duration: nil, reason: "indefinite while locked")
        XCTAssertEqual(service.state, .active(mode: .systemOnly, expiresAt: nil, reason: "indefinite while locked"))
    }

    func testReleaseAlwaysWorksWhileLocked() throws {
        // The escape hatch: a conditional hold armed under a valid
        // entitlement must remain releasable after the entitlement lapses.
        let service = PowerControlService(defaults: makeTestDefaults("lockedRelease"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "armed before lapse")
        service.conditionalKeepAwakeAuthorized = { false }

        service.releaseAssertion()
        XCTAssertEqual(service.state, .inactive)
    }

    // MARK: - Unlock, and flips are live

    func testEntitlementFlipIsLiveAtTheVeryNextArm() throws {
        // The closure is consulted at arm time, not mirrored — so no
        // settings tick, relaunch, or re-push is needed between a license
        // paste and the next successful arm.
        let service = PowerControlService(defaults: makeTestDefaults("liveFlip"))
        defer { service.releaseAssertion() }
        var unlocked = false
        service.conditionalKeepAwakeAuthorized = { unlocked }

        XCTAssertThrowsError(
            try service.startConditionalAssertion(mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "still locked")
        ) { error in
            XCTAssertEqual(error as? PowerControlError, .conditionalKeepAwakeLocked)
        }

        unlocked = true
        try service.startConditionalAssertion(mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "unlocked arm")
        XCTAssertEqual(service.state, .active(mode: .systemOnly, expiresAt: nil, reason: "unlocked arm"))

        unlocked = false
        service.releaseAssertion()
        XCTAssertThrowsError(
            try service.startConditionalAssertion(mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "locked again")
        )
    }

    // MARK: - Lapse policy for an already-armed hold

    func testLapseKeepsAnArmedHoldRunningAndItsConditionStillReleases() throws {
        // The documented mid-session lapse behavior: the gate blocks new
        // arms only. The armed hold neither drops at the lapse instant
        // (sleeping the Mac out from under the user's workload) nor
        // degrades into an unreleasable indefinite hold — its condition
        // keeps being evaluated and keeps releasing.
        let service = PowerControlService(defaults: makeTestDefaults("lapsePolicy"))
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "armed before lapse")
        service.conditionalKeepAwakeAuthorized = { false }

        service.evaluate(snapshot(batteryPercent: 55))
        XCTAssertNotEqual(service.state, .inactive, "a lapse must not release an armed hold whose condition hasn't fired")

        service.evaluate(snapshot(batteryPercent: 10))
        XCTAssertEqual(service.state, .inactive, "the condition must keep releasing after a lapse — releasing is never gated")
    }

    func testWakeRestoreWhileLockedDropsThePersistedConditionalHold() throws {
        // The restore path re-arms through the same gated internal start,
        // so a conditional hold whose license lapsed while the Mac slept is
        // dropped by `reconcilePersistedState`'s existing catch (released,
        // logged, record cleared) rather than resurrected — and rather than
        // leaving `state` claiming a condition is being watched that never
        // re-armed.
        let defaults = makeTestDefaults("lockedWakeRestore")
        let service = PowerControlService(defaults: defaults)
        defer { service.releaseAssertion() }

        try service.startConditionalAssertion(mode: .systemOnly, condition: .batteryBelowPercent(20), reason: "armed before sleep")
        service.conditionalKeepAwakeAuthorized = { false }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let resumed = expectation(description: "wake reconciliation ran")
        DispatchQueue.main.async { resumed.fulfill() }
        wait(for: [resumed], timeout: 2)

        XCTAssertEqual(service.state, .inactive, "a lapsed license must not resurrect a conditional hold at wake")
        XCTAssertNil(
            defaults.data(forKey: "dev.malekswilam.sentry.powercontrol.state"),
            "the undead record must be cleared, not left to fool the next reconcile"
        )
    }

    // MARK: - UI helpers: the withheld menu

    func testVisibleOptionsUnlockedIsExactlyTheFullMenuInOrder() {
        XCTAssertEqual(
            SleepTriggerOption.visibleOptions(isUnlocked: true),
            SleepTriggerOption.allOptions,
            "unlocking must restore the exact menu testMenuOrderMatchesPlanSection103 pins"
        )
    }

    func testVisibleOptionsLockedWithholdsExactlyTheConditionalTriggers() {
        let locked = SleepTriggerOption.visibleOptions(isUnlocked: false)
        XCTAssertEqual(
            locked.map(\.id),
            ["indefinite", "fixed-900", "fixed-1800", "fixed-3600", "fixed-7200", "fixed-14400", "fixed-28800", "until-time"]
        )
        XCTAssertFalse(locked.contains { $0.isConditional })
        // The filter withholds, it doesn't reorder: what remains is
        // `allOptions` minus the conditional cases, in `allOptions` order.
        XCTAssertEqual(locked, SleepTriggerOption.allOptions.filter { !$0.isConditional })
    }

    /// `isConditional` and `releaseCondition(...)` are two spellings of the
    /// same boundary; if they ever disagree, either a free trigger gets
    /// paywalled or a Pro trigger arms for free.
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

    // MARK: - No Pro strings leak to the free tier

    func testLockedMenuTitleNamesTheFeatureAndCountWithoutTriggerVocabulary() {
        let title = SleepTriggerOption.lockedOptionsMenuTitle
        XCTAssertTrue(title.contains(ProFeature.conditionalKeepAwake.displayName))

        let withheldCount = SleepTriggerOption.allOptions.count
            - SleepTriggerOption.visibleOptions(isUnlocked: false).count
        XCTAssertEqual(withheldCount, 5, "the launch menu withholds the five conditional triggers")
        XCTAssertTrue(title.contains("\(withheldCount)"), "the locked row's count must be the real one")

        // The whole point of "withheld, not obscured": none of the locked
        // triggers' own menu text may appear in the one string the free
        // tier sees.
        for option in SleepTriggerOption.allOptions where option.isConditional {
            XCTAssertFalse(
                title.contains(option.pickerLabel),
                "locked row must not name the withheld trigger “\(option.pickerLabel)”"
            )
        }
    }

    func testLockedErrorNamesTheTierAndEnumeratesNothing() {
        let message = PowerControlError.conditionalKeepAwakeLocked.errorDescription ?? ""
        XCTAssertTrue(message.contains("Sentry Pro"))
        // Rendered verbatim by `SleepControlCard.errorRow` (and any future
        // surface), so it must not smuggle the trigger list out either.
        for word in ["battery", "CPU", "process", "download", "schedule"] {
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains(word),
                "locked error must not enumerate the “\(word)” trigger"
            )
        }
    }
}
