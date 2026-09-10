import CryptoKit
import XCTest
@testable import SentryKit

/// `LicenseRevalidationScheduler` (`SentryKit/Pro/`): inert unless a client
/// *and* a grace-window policy are both present; otherwise a repeating
/// call to `LicenseProEntitlementStore.revalidate()` whose errors are
/// absorbed. Intervals here are milliseconds so the loop can be observed;
/// production uses `dailyInterval`.
///
/// TEST-ONLY keys, pinned `now` — see `LicenseTestSupport`.
@MainActor
final class LicenseRevalidationSchedulerTests: XCTestCase {

    private let testKey = Curve25519.Signing.PrivateKey()
    private let now = LicenseTestSupport.pinnedNow

    private func makeStore(
        client: StubLicenseActivationClient?,
        policy: LicenseRevalidationPolicy,
        installed: Bool = true,
        lastVerifiedAt: Date? = nil
    ) throws -> (LicenseProEntitlementStore, SettingsStore) {
        let settings = LicenseTestSupport.makeSettingsStore()
        if installed {
            settings.settings.proLicenseBlob = try LicenseTestSupport.signedBlob(LicenseTestSupport.payload(), key: testKey)
            settings.settings.proLicenseLastVerifiedAt = lastVerifiedAt ?? now.addingTimeInterval(-LicenseTestSupport.day)
        }
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settings,
            publicKey: testKey.publicKey,
            activationClient: client,
            revalidationPolicy: policy,
            now: { pinned }
        )
        return (store, settings)
    }

    private func settle(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: - Inert: the state this build ships in

    /// The composition root's actual configuration: no client, `.never`.
    func testNoClientAndNeverPolicyIsInert() throws {
        let (store, _) = try makeStore(client: nil, policy: .never)
        XCTAssertFalse(store.isOnlineRevalidationArmed)

        let scheduler = LicenseRevalidationScheduler(store: store, interval: 0.01, now: { self.now })
        XCTAssertEqual(scheduler.state, .stopped)
        scheduler.start()

        guard case .inert(let reason) = scheduler.state else {
            return XCTFail("expected .inert, got \(scheduler.state)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("activation client"))
        XCTAssertNil(scheduler.lastAttemptAt)
    }

    /// A client with nothing to refresh: still inert, and the client is
    /// never called — a `.never` policy means the answer would change
    /// nothing, so asking is pure network noise.
    func testClientWithNeverPolicyIsInertAndNeverCallsTheClient() async throws {
        let client = StubLicenseActivationClient()
        let (store, _) = try makeStore(client: client, policy: .never)
        XCTAssertFalse(store.isOnlineRevalidationArmed)

        let scheduler = LicenseRevalidationScheduler(store: store, interval: 0.01, now: { self.now })
        scheduler.start()
        try await settle(100)

        guard case .inert(let reason) = scheduler.state else {
            return XCTFail("expected .inert, got \(scheduler.state)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("policy"))
        XCTAssertTrue(client.revalidateCalls.isEmpty)
    }

    /// The forbidden half-flip. The scheduler can't rescue it (there is no
    /// one to call) but it must not pretend to be doing something.
    func testStandardPolicyWithoutClientIsInert() throws {
        let (store, _) = try makeStore(client: nil, policy: .standard)
        XCTAssertFalse(store.isOnlineRevalidationArmed)
        let scheduler = LicenseRevalidationScheduler(store: store, interval: 0.01, now: { self.now })
        scheduler.start()
        guard case .inert = scheduler.state else {
            return XCTFail("expected .inert, got \(scheduler.state)")
        }
    }

    // MARK: - Armed: what Part 5b will get

    func testArmedStoreRunsImmediatelyThenRepeats() async throws {
        let client = StubLicenseActivationClient(revalidate: .answer(.stillValid(refreshedBlob: nil)))
        let (store, settings) = try makeStore(client: client, policy: .standard)
        XCTAssertTrue(store.isOnlineRevalidationArmed)

        let scheduler = LicenseRevalidationScheduler(store: store, interval: 0.05, now: { self.now })
        scheduler.start()
        XCTAssertEqual(scheduler.state, .scheduled(interval: 0.05))

        try await settle(300)

        XCTAssertGreaterThanOrEqual(client.revalidateCalls.count, 2, "the check must repeat, not fire once")
        XCTAssertEqual(Set(client.revalidateCalls), [LicenseTestSupport.payload().licenseID])
        XCTAssertEqual(scheduler.lastAttemptAt, now)
        XCTAssertNil(scheduler.lastError)
        // A still-valid answer refreshed the stamp to the pinned clock.
        XCTAssertEqual(settings.settings.proLicenseLastVerifiedAt, now)
        XCTAssertTrue(store.isUnlocked(.protectionInsights))

        scheduler.stop()
    }

    func testTransportErrorsAreAbsorbedAndTheLicenseIsLeftAlone() async throws {
        let client = StubLicenseActivationClient(revalidate: .throwError(URLError(.notConnectedToInternet)))
        let (store, settings) = try makeStore(client: client, policy: .standard)
        let stampBefore = settings.settings.proLicenseLastVerifiedAt

        let scheduler = LicenseRevalidationScheduler(store: store, interval: 0.05, now: { self.now })
        scheduler.start()
        try await settle(150)

        XCTAssertGreaterThanOrEqual(client.revalidateCalls.count, 1)
        XCTAssertNotNil(scheduler.lastError)
        // Still scheduled — one failure doesn't stop the loop.
        XCTAssertEqual(scheduler.state, .scheduled(interval: 0.05))
        // Unreachable is not negative: entitlement and the stamp are
        // untouched, and the grace window does its job.
        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(settings.settings.proLicenseLastVerifiedAt, stampBefore)

        scheduler.stop()
    }

    func testRevokedAnswerOnAScheduledTickRemovesTheLicense() async throws {
        let client = StubLicenseActivationClient(revalidate: .answer(.revoked(reason: "chargeback")))
        let (store, settings) = try makeStore(client: client, policy: .standard)
        XCTAssertTrue(store.isUnlocked(.protectionInsights))

        let scheduler = LicenseRevalidationScheduler(store: store, interval: 1, now: { self.now })
        scheduler.start()
        try await settle(100)

        XCTAssertEqual(client.revalidateCalls.count, 1)
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertNil(settings.settings.proLicenseBlob)
        XCTAssertEqual(store.decision, .denied(.noLicense))

        scheduler.stop()
    }

    func testStopEndsTheLoop() async throws {
        let client = StubLicenseActivationClient()
        let (store, _) = try makeStore(client: client, policy: .standard)
        let scheduler = LicenseRevalidationScheduler(store: store, interval: 0.03, now: { self.now })
        scheduler.start()
        try await settle(100)
        scheduler.stop()
        XCTAssertEqual(scheduler.state, .stopped)

        try await settle(100)
        let afterStop = client.revalidateCalls.count
        try await settle(150)
        XCTAssertEqual(client.revalidateCalls.count, afterStop, "no further calls after stop()")
    }

    func testStartIsIdempotentWhileScheduled() throws {
        let client = StubLicenseActivationClient()
        let (store, _) = try makeStore(client: client, policy: .standard)
        let scheduler = LicenseRevalidationScheduler(store: store, interval: 10, now: { self.now })
        scheduler.start()
        scheduler.start()
        XCTAssertEqual(scheduler.state, .scheduled(interval: 10))
        scheduler.stop()
    }

    /// Armed but nothing installed: a tick asks nobody. There is no
    /// license ID to send, and the store says so by returning nil.
    func testArmedWithNoLicenseInstalledDoesNotCallTheClient() async throws {
        let client = StubLicenseActivationClient()
        let (store, _) = try makeStore(client: client, policy: .standard, installed: false)
        let scheduler = LicenseRevalidationScheduler(store: store, interval: 0.03, now: { self.now })
        scheduler.start()
        try await settle(100)
        XCTAssertTrue(client.revalidateCalls.isEmpty)
        XCTAssertNil(scheduler.lastError)
        scheduler.stop()
    }
}
