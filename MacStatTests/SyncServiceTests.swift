import CloudKit
import XCTest
import MacStatKit

/// Coverage for `SyncService` (`MacStatKit/Sync/SyncService.swift`) — plan
/// §7.4's adaptive-cadence rate-limiting table, the "significant event
/// forces immediate upload" override, and the exponential-backoff-with-jitter
/// math. No real `CKContainer`/`CKDatabase` is ever touched: every upload
/// attempt is routed through an injected `UploadAttempt` closure (see
/// `SyncService.swift`'s doc comment for why — no enrolled Apple Developer
/// Program account exists for this project yet).
final class SyncServiceTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "MacStatZone", ownerName: CKCurrentUserDefaultName)

    private func sampleSnapshot(deviceID: String = "device-1", timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SnapshotRecord {
        SnapshotRecord(
            deviceID: deviceID,
            timestamp: timestamp,
            schemaVersion: 1,
            payload: Data([0x1f, 0x8b]),
            batteryPercent: 87,
            batteryHealth: 92,
            chargingWatts: 0,
            cpuPercent: 12.5,
            memoryPercent: 44,
            isAwakeAsserted: false
        )
    }

    // MARK: - Cadence table (plan §7.4), pure function

    func testACOnAndIPhoneRecentlyActiveUsesFastInterval() {
        let interval = SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: true)
        XCTAssertEqual(interval, 30)
    }

    func testACOnAndIPhoneIdleUsesFiveMinuteInterval() {
        let interval = SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: false)
        XCTAssertEqual(interval, 300)
    }

    func testOnBatteryUsesTenMinuteIntervalRegardlessOfIPhoneActivity() {
        XCTAssertEqual(SyncService.effectiveInterval(onBattery: true, iPhoneRecentlyActive: true), 600)
        XCTAssertEqual(SyncService.effectiveInterval(onBattery: true, iPhoneRecentlyActive: false), 600)
    }

    func testCustomIntervalsAreHonored() {
        let interval = SyncService.effectiveInterval(
            onBattery: false,
            iPhoneRecentlyActive: true,
            acActiveInterval: 10,
            acIdleInterval: 120,
            batteryInterval: 240
        )
        XCTAssertEqual(interval, 10)
    }

    // MARK: - Cadence table, driven through a live instance

    func testInstanceReflectsACActiveCadence() {
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { Date(timeIntervalSince1970: 1_000_000) })
        service.updatePowerState(onBattery: false)
        service.recordIPhoneActivity(at: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(service.currentEffectiveInterval(), 30)
    }

    func testInstanceReflectsACIdleCadenceAfterTenMinutesOfNoIPhoneActivity() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var now = start
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { now })
        service.updatePowerState(onBattery: false)
        service.recordIPhoneActivity(at: start)

        // Still inside the 10-minute window.
        now = start.addingTimeInterval(9 * 60)
        XCTAssertEqual(service.currentEffectiveInterval(), 30)

        // Past the 10-minute window.
        now = start.addingTimeInterval(10 * 60 + 1)
        XCTAssertEqual(service.currentEffectiveInterval(), 300)
    }

    func testInstanceReflectsBatteryCadence() {
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { Date(timeIntervalSince1970: 1_000_000) })
        service.recordIPhoneActivity(at: Date(timeIntervalSince1970: 1_000_000))
        service.updatePowerState(onBattery: true)
        XCTAssertEqual(service.currentEffectiveInterval(), 600)
    }

    func testIPhoneNeverActiveIsTreatedAsNotRecentlyActive() {
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { Date(timeIntervalSince1970: 1_000_000) })
        service.updatePowerState(onBattery: false)
        // recordIPhoneActivity is never called.
        XCTAssertEqual(service.currentEffectiveInterval(), 300)
    }

    // MARK: - Significant event / refreshNow forces immediate upload

    func testSignificantEventForcesNextTickImmediateWithoutChangingCadence() {
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { Date(timeIntervalSince1970: 1_000_000) })
        service.updatePowerState(onBattery: false)
        service.recordIPhoneActivity(at: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(service.currentEffectiveInterval(), 30, "baseline cadence before the event")

        service.noteSignificantEvent()

        XCTAssertEqual(service.nextTickDelay(), 0, "a significant event must force the very next tick immediate")
        XCTAssertEqual(service.currentEffectiveInterval(), 30, "the underlying cadence itself is unaffected by the override")
    }

    func testRefreshNowRequestForcesImmediateTick() async {
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { Date(timeIntervalSince1970: 1_000_000) })
        service.updatePowerState(onBattery: true) // slow cadence
        // The false -> true power transition is itself a significant event
        // (covered separately by testPluggingOrUnpluggingIsTreatedAsASignificantEvent);
        // run one tick to consume that override so this test isolates the
        // refreshNow trigger specifically.
        await service.runTickForTesting()
        XCTAssertEqual(service.nextTickDelay(), 600)

        service.handleRefreshNowRequested()

        XCTAssertEqual(service.nextTickDelay(), 0)
    }

    func testPluggingOrUnpluggingIsTreatedAsASignificantEvent() {
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { Date(timeIntervalSince1970: 1_000_000) })
        service.updatePowerState(onBattery: false)
        XCTAssertEqual(service.nextTickDelay(), 300, "AC, no iPhone activity yet")

        // Real transition (false -> true) should force the override.
        service.updatePowerState(onBattery: true)
        XCTAssertEqual(service.nextTickDelay(), 0)
    }

    func testRepeatingTheSamePowerStateDoesNotForceAnImmediateTick() {
        let service = SyncService(uploadAttempt: { _ in .success }, clock: { Date(timeIntervalSince1970: 1_000_000) })
        service.updatePowerState(onBattery: false)
        // Consume any override from the very first transition away from the
        // default (false), if one was queued, by reading it once.
        _ = service.nextTickDelay()

        service.updatePowerState(onBattery: false) // no change
        XCTAssertEqual(service.nextTickDelay(), 300, "reporting the same power state again must not force an immediate tick")
    }

    // MARK: - Backoff math: exponential growth

    func testBackoffGrowsExponentiallyAcrossConsecutiveFailures() {
        // Jitter pinned to 1.0 (the upper bound) so the sequence is exact
        // and deterministic: baseDelay * 2^(attempt-1), capped.
        let delays = (1...6).map {
            SyncService.backoffDelay(attempt: $0, baseDelay: 2, maxDelay: 1000, jitterUnit: { 1.0 })
        }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 64])
    }

    func testBackoffIsCappedAtMaxDelay() {
        let delay = SyncService.backoffDelay(attempt: 20, baseDelay: 2, maxDelay: 300, jitterUnit: { 1.0 })
        XCTAssertEqual(delay, 300)
    }

    func testBackoffAttemptsBelowOneAreTreatedAsAttemptOne() {
        let zero = SyncService.backoffDelay(attempt: 0, baseDelay: 5, maxDelay: 1000, jitterUnit: { 1.0 })
        let negative = SyncService.backoffDelay(attempt: -3, baseDelay: 5, maxDelay: 1000, jitterUnit: { 1.0 })
        let one = SyncService.backoffDelay(attempt: 1, baseDelay: 5, maxDelay: 1000, jitterUnit: { 1.0 })
        XCTAssertEqual(zero, one)
        XCTAssertEqual(negative, one)
    }

    // MARK: - Backoff math: jitter present but bounded

    func testJitterIsPresentAndBoundedWithinTheCappedWindow() {
        let capped: TimeInterval = min(300, 2 * pow(2.0, 4.0)) // attempt 5 -> 32
        let lower = SyncService.backoffDelay(attempt: 5, baseDelay: 2, maxDelay: 300, jitterUnit: { 0.0 })
        let upper = SyncService.backoffDelay(attempt: 5, baseDelay: 2, maxDelay: 300, jitterUnit: { 1.0 })
        let mid = SyncService.backoffDelay(attempt: 5, baseDelay: 2, maxDelay: 300, jitterUnit: { 0.5 })

        XCTAssertEqual(lower, 0)
        XCTAssertEqual(upper, capped)
        XCTAssertEqual(mid, capped * 0.5)
        XCTAssertLessThanOrEqual(upper, capped)
        XCTAssertGreaterThanOrEqual(lower, 0)
    }

    func testJitterUnitIsClampedEvenIfInjectedSourceMisbehaves() {
        // A pathological jitter source outside 0...1 must not push the
        // delay outside the capped window.
        let tooHigh = SyncService.backoffDelay(attempt: 3, baseDelay: 2, maxDelay: 300, jitterUnit: { 5.0 })
        let tooLow = SyncService.backoffDelay(attempt: 3, baseDelay: 2, maxDelay: 300, jitterUnit: { -5.0 })
        XCTAssertEqual(tooHigh, 8) // capped at capped * 1.0
        XCTAssertEqual(tooLow, 0) // floored at capped * 0.0
    }

    // MARK: - Backoff math: explicit retryAfterSeconds wins

    func testExplicitRetryAfterSecondsOverridesComputedBackoff() {
        // Even though attempt 6 would compute to a large exponential delay,
        // an explicit server-provided value must win outright, unjittered.
        let delay = SyncService.backoffDelay(
            attempt: 6,
            baseDelay: 2,
            maxDelay: 1000,
            retryAfterSeconds: 17,
            jitterUnit: { 1.0 }
        )
        XCTAssertEqual(delay, 17)
    }

    func testNegativeRetryAfterSecondsIsFlooredAtZero() {
        let delay = SyncService.backoffDelay(attempt: 1, retryAfterSeconds: -5)
        XCTAssertEqual(delay, 0)
    }

    // MARK: - End-to-end tick: success clears the queue and resets failures

    func testSuccessfulTickUploadsQueuedRecordsAndResetsFailureCount() async {
        var receivedBatches: [UploadBatch] = []
        let service = SyncService(uploadAttempt: { batch in
            receivedBatches.append(batch)
            return .success
        })

        service.enqueueSnapshot(sampleSnapshot(), zoneID: zoneID)
        XCTAssertEqual(service.pendingRecordCount(), 1)

        await service.runTickForTesting()

        XCTAssertEqual(receivedBatches.count, 1)
        XCTAssertEqual(receivedBatches.first?.recordsToSave.count, 1)
        XCTAssertEqual(receivedBatches.first?.savePolicy, .changedKeys)
        XCTAssertEqual(receivedBatches.first?.qualityOfService, .utility)
        XCTAssertEqual(service.pendingRecordCount(), 0, "a successful upload must drain the pending queue")
        XCTAssertEqual(service.consecutiveFailureCount(), 0)
    }

    func testTickWithNothingQueuedNeverCallsUploadAttempt() async {
        var callCount = 0
        let service = SyncService(uploadAttempt: { _ in
            callCount += 1
            return .success
        })

        await service.runTickForTesting()

        XCTAssertEqual(callCount, 0, "batching must never fire an empty upload")
    }

    // MARK: - End-to-end tick: failure requeues records and increments failure count

    func testFailedTickRequeuesRecordsAndIncrementsFailureCount() async {
        let service = SyncService(uploadAttempt: { _ in .failure(retryAfterSeconds: nil) })

        service.enqueueSnapshot(sampleSnapshot(), zoneID: zoneID)
        await service.runTickForTesting()

        XCTAssertEqual(service.pendingRecordCount(), 1, "a failed upload must not lose the queued record")
        XCTAssertEqual(service.consecutiveFailureCount(), 1)
    }

    func testControlStatusUsesUserInitiatedQoSAndForcesImmediateTick() async {
        var receivedBatches: [UploadBatch] = []
        let service = SyncService(uploadAttempt: { batch in
            receivedBatches.append(batch)
            return .success
        })

        let status = ControlStatus(
            deviceID: "device-1",
            respondsToNonce: "nonce-1",
            state: "completed",
            message: "",
            assertionActive: false,
            assertionExpiresAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        service.enqueueControlStatus(status, zoneID: zoneID)

        XCTAssertEqual(service.nextTickDelay(), 0, "an acknowledgement is significant-event urgency")

        await service.runTickForTesting()

        XCTAssertEqual(receivedBatches.first?.qualityOfService, .userInitiated)
    }
}
