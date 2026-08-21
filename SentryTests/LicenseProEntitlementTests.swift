import CryptoKit
import XCTest
@testable import SentryKit

/// Tests for the license verification half of the Pro system: the
/// `SignedLicense` blob format, `LicenseEntitlementPolicy`'s grace logic,
/// and `LicenseProEntitlementStore`'s wiring.
///
/// **Every key in this file is TEST-ONLY.** Key pairs are generated fresh
/// at runtime with `Curve25519.Signing.PrivateKey()` — no key material is
/// committed, and nothing signed here could ever verify against a real
/// production key (`LicenseKeys.productionPublicKey`), which remains nil
/// in this build precisely so no development machine ever holds a private
/// key that matters.
///
/// **Every date is pinned.** `now` is a fixed instant and all issue,
/// expiry, and verification times are offsets from it — `Date()` appears
/// in no assertion, per the same discipline as
/// `ProtectionInsightsEngineTests`.
final class LicenseProEntitlementTests: XCTestCase {

    /// The pinned "current instant" for every decision in this file.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// TEST-ONLY signing key, minted per test-case instance at runtime.
    private let testKey = Curve25519.Signing.PrivateKey()

    private let day: TimeInterval = 24 * 3600

    // MARK: - Helpers

    private func makePayload(
        licenseID: String = "9C1B2A6E-0000-4000-8000-DEADBEEF0001",
        email: String = "buyer@example.com",
        seats: Int = 2,
        issuedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> LicensePayload {
        LicensePayload(
            licenseID: licenseID,
            emailSHA256: LicensePayload.emailHash(email),
            seats: seats,
            issuedAt: Int((issuedAt ?? now.addingTimeInterval(-30 * day)).timeIntervalSince1970),
            expiresAt: expiresAt.map { Int($0.timeIntervalSince1970) }
        )
    }

    /// Signs with the TEST-ONLY key (or a caller-supplied one, for the
    /// wrong-key case) exactly the way the real issuing side would: encode
    /// the payload as JSON, sign those exact bytes, compose the blob.
    private func signedBlob(
        _ payload: LicensePayload,
        key: Curve25519.Signing.PrivateKey? = nil
    ) throws -> String {
        let signingKey = key ?? testKey
        let json = try JSONEncoder().encode(payload)
        let signature = try signingKey.signature(for: json)
        return SignedLicense.compose(payloadJSON: json, signature: signature)
    }

    /// A `SettingsStore` on a throwaway URL with a debounce long enough
    /// that no test ever races a disk write. Assertions read the in-memory
    /// `settings` value.
    private func makeSettingsStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("license-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        return SettingsStore(fileURL: url, debounceInterval: 3600)
    }

    // MARK: - Blob format & signature verification

    func testValidPerpetualLicenseVerifies() throws {
        let payload = makePayload(expiresAt: nil)
        let blob = try signedBlob(payload)

        // Perpetual means perpetual: still valid a decade of pinned time later.
        for at in [now, now.addingTimeInterval(3650 * day)] {
            guard case .valid(let verified) = SignedLicense.verify(blob: blob, publicKey: testKey.publicKey, at: at) else {
                return XCTFail("perpetual license should verify at \(at)")
            }
            XCTAssertEqual(verified, payload)
            XCTAssertTrue(verified.isPerpetual)
            XCTAssertNil(verified.expiryDate)
        }
    }

    func testValidExpiringLicenseVerifiesBeforeExpiryAndRoundTripsFields() throws {
        let expiry = now.addingTimeInterval(365 * day)
        let payload = makePayload(seats: 5, expiresAt: expiry)
        let blob = try signedBlob(payload)

        guard case .valid(let verified) = SignedLicense.verify(blob: blob, publicKey: testKey.publicKey, at: now) else {
            return XCTFail("expiring license should verify before expiry")
        }
        XCTAssertEqual(verified.seats, 5)
        XCTAssertEqual(verified.emailSHA256, LicensePayload.emailHash("buyer@example.com"))
        XCTAssertEqual(verified.expiryDate, Date(timeIntervalSince1970: TimeInterval(Int(expiry.timeIntervalSince1970))))
        XCTAssertFalse(verified.isPerpetual)
    }

    func testEmailHashNormalizesCaseAndWhitespace() {
        XCTAssertEqual(
            LicensePayload.emailHash("  Buyer@Example.COM \n"),
            LicensePayload.emailHash("buyer@example.com")
        )
        // And it is a hash, not the address: 64 hex chars, no '@'.
        let hash = LicensePayload.emailHash("buyer@example.com")
        XCTAssertEqual(hash.count, 64)
        XCTAssertFalse(hash.contains("@"))
    }

    func testTamperedPayloadFailsSignature() throws {
        // Sign the honest payload, then swap in a payload with more seats
        // while keeping the original signature — the classic tamper.
        let honest = makePayload(seats: 1)
        let honestJSON = try JSONEncoder().encode(honest)
        let signature = try testKey.signature(for: honestJSON)

        var greedy = honest
        greedy.seats = 500
        let greedyJSON = try JSONEncoder().encode(greedy)
        let tampered = SignedLicense.compose(payloadJSON: greedyJSON, signature: signature)

        XCTAssertEqual(
            SignedLicense.verify(blob: tampered, publicKey: testKey.publicKey, at: now),
            .signatureInvalid
        )
    }

    func testWrongPublicKeyFailsSignature() throws {
        // TEST-ONLY second key: a blob signed by someone else entirely.
        let otherKey = Curve25519.Signing.PrivateKey()
        let blob = try signedBlob(makePayload(), key: otherKey)

        XCTAssertEqual(
            SignedLicense.verify(blob: blob, publicKey: testKey.publicKey, at: now),
            .signatureInvalid
        )
    }

    func testTruncatedSignatureFailsCleanlyAsInvalidNotCrash() throws {
        let payload = makePayload()
        let json = try JSONEncoder().encode(payload)
        let signature = try testKey.signature(for: json)
        let truncated = SignedLicense.compose(payloadJSON: json, signature: signature.prefix(16))

        XCTAssertEqual(
            SignedLicense.verify(blob: truncated, publicKey: testKey.publicKey, at: now),
            .signatureInvalid
        )
    }

    func testExpiryBoundaryLicenseIsGoodStrictlyUntilTheExpiryInstant() throws {
        let expiry = now  // expires exactly at the pinned instant
        let blob = try signedBlob(makePayload(expiresAt: expiry))

        // One second before expiry: valid.
        if case .valid = SignedLicense.verify(blob: blob, publicKey: testKey.publicKey, at: now.addingTimeInterval(-1)) {
        } else {
            XCTFail("license should be valid one second before expiry")
        }

        // At the expiry instant itself: expired (the `>=` boundary
        // documented in `SignedLicense.verify`).
        guard case .expired(let payload, let expiredAt) = SignedLicense.verify(blob: blob, publicKey: testKey.publicKey, at: now) else {
            return XCTFail("license should be expired at its expiry instant")
        }
        XCTAssertEqual(expiredAt, Date(timeIntervalSince1970: TimeInterval(Int(expiry.timeIntervalSince1970))))
        // The payload comes back with `expired` — genuine-but-lapsed keeps
        // its identity, which is what lets UI say *when* it expired.
        XCTAssertEqual(payload.licenseID, makePayload().licenseID)
    }

    func testMalformedBlobsReportMalformedNotCrash() {
        let malformed = [
            "",
            "sentry-pro-v1",                       // 1 segment
            "sentry-pro-v1.onlyone",               // 2 segments
            "sentry-pro-v1.a.b.c",                 // 4 segments
            "sentry-pro-v1.!!!not-base64.AAAA",    // undecodable payload
            "sentry-pro-v1.AAAA.!!!not-base64",    // undecodable signature
        ]
        for blob in malformed {
            guard case .malformed = SignedLicense.verify(blob: blob, publicKey: testKey.publicKey, at: now) else {
                return XCTFail("expected .malformed for \(blob.debugDescription)")
            }
        }
    }

    func testSignedButUnreadablePayloadIsMalformedNotSignatureInvalid() throws {
        // Correctly signed bytes that aren't a LicensePayload — e.g. a
        // future schema signed by the same key. The crypto passed, so this
        // must be .malformed, never .signatureInvalid.
        let notAPayload = Data(#"{"someFutureField":true}"#.utf8)
        let signature = try testKey.signature(for: notAPayload)
        let blob = SignedLicense.compose(payloadJSON: notAPayload, signature: signature)

        guard case .malformed = SignedLicense.verify(blob: blob, publicKey: testKey.publicKey, at: now) else {
            return XCTFail("expected .malformed for signed-but-unreadable payload")
        }
    }

    func testUnsupportedPrefixIsItsOwnOutcome() throws {
        let blob = try signedBlob(makePayload())
        let futureBlob = blob.replacingOccurrences(of: "sentry-pro-v1.", with: "sentry-pro-v2.")

        XCTAssertEqual(
            SignedLicense.verify(blob: futureBlob, publicKey: testKey.publicKey, at: now),
            .unsupportedFormat(prefix: "sentry-pro-v2")
        )
    }

    func testSurroundingWhitespaceIsToleratedTheWayPastedTextArrives() throws {
        let blob = try signedBlob(makePayload())
        let pasted = "\n  " + blob + "  \n"

        guard case .valid = SignedLicense.verify(blob: pasted, publicKey: testKey.publicKey, at: now) else {
            return XCTFail("whitespace-padded paste should still verify")
        }
    }

    // MARK: - Entitlement policy (grace window, pinned dates throughout)

    func testNoBlobIsDeniedAsNoLicenseEvenWithoutAKey() {
        // Keyless build, nothing installed: the ordinary unpaid state, not
        // the build-gap state — order documented on `decide`.
        XCTAssertEqual(
            LicenseEntitlementPolicy.decide(blob: nil, publicKey: nil, lastVerifiedAt: nil, policy: .never, now: now),
            .denied(.noLicense)
        )
    }

    func testBlobWithoutEmbeddedKeyIsDeniedWithTheBuildGapReason() throws {
        let blob = try signedBlob(makePayload())
        let decision = LicenseEntitlementPolicy.decide(
            blob: blob, publicKey: nil, lastVerifiedAt: nil, policy: .never, now: now
        )
        XCTAssertEqual(decision, .denied(.verificationUnavailableInThisBuild))
    }

    func testNeverPolicyEntitlesAValidLicenseRegardlessOfLastVerified() throws {
        let blob = try signedBlob(makePayload())
        for lastVerified in [nil, now.addingTimeInterval(-3650 * day)] as [Date?] {
            let decision = LicenseEntitlementPolicy.decide(
                blob: blob, publicKey: testKey.publicKey,
                lastVerifiedAt: lastVerified, policy: .never, now: now
            )
            XCTAssertTrue(decision.isEntitled)
        }
    }

    func testGraceWindowBoundaries() throws {
        let blob = try signedBlob(makePayload())
        let policy = LicenseRevalidationPolicy(graceWindow: 14 * day)

        func decide(lastVerifiedAt: Date?) -> LicenseEntitlementDecision {
            LicenseEntitlementPolicy.decide(
                blob: blob, publicKey: testKey.publicKey,
                lastVerifiedAt: lastVerifiedAt, policy: policy, now: now
            )
        }

        // Comfortably inside the window.
        XCTAssertTrue(decide(lastVerifiedAt: now.addingTimeInterval(-1 * day)).isEntitled)

        // Exactly at the edge: still trusted (inclusive boundary,
        // documented on `decide`).
        XCTAssertTrue(decide(lastVerifiedAt: now.addingTimeInterval(-14 * day)).isEntitled)

        // One second past the edge: lapsed, carrying the honest details.
        let stale = now.addingTimeInterval(-14 * day - 1)
        XCTAssertEqual(
            decide(lastVerifiedAt: stale),
            .denied(.revalidationLapsed(lastVerifiedAt: stale, graceWindow: 14 * day))
        )

        // Never verified under a revalidation-requiring policy: lapsed
        // from the start, not entitled by omission.
        XCTAssertEqual(
            decide(lastVerifiedAt: nil),
            .denied(.revalidationLapsed(lastVerifiedAt: nil, graceWindow: 14 * day))
        )
    }

    func testExpiryBeatsAFreshRevalidation() throws {
        let blob = try signedBlob(makePayload(expiresAt: now.addingTimeInterval(-1 * day)))
        let decision = LicenseEntitlementPolicy.decide(
            blob: blob, publicKey: testKey.publicKey,
            lastVerifiedAt: now,  // server vouched a moment ago — irrelevant to term
            policy: LicenseRevalidationPolicy(graceWindow: 14 * day),
            now: now
        )
        guard case .denied(.expired) = decision else {
            return XCTFail("an expired license must be denied as expired even with a fresh revalidation")
        }
    }

    func testEveryDenialReasonHasOnScreenLanguage() {
        // The house rule for every gate in this app: a state that blocks
        // something must say why in plain language. Every case, no empty
        // strings.
        let reasons: [LicenseDenialReason] = [
            .noLicense,
            .verificationUnavailableInThisBuild,
            .malformed(reason: "x"),
            .unsupportedFormat(prefix: "sentry-pro-v9"),
            .signatureInvalid,
            .expired(on: now),
            .revalidationLapsed(lastVerifiedAt: now, graceWindow: day),
        ]
        for reason in reasons {
            XCTAssertFalse(reason.explanation.isEmpty, "no explanation for \(reason)")
        }
    }

    // MARK: - LicenseProEntitlementStore wiring

    @MainActor
    func testInstallValidLicenseUnlocksAndPersistsBlobAndTimestamp() throws {
        let settingsStore = makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            now: { pinned }
        )
        XCTAssertFalse(store.isUnlocked(.protectionInsights))

        let blob = try signedBlob(makePayload())
        let result = store.installLicense(blob)

        XCTAssertTrue(result.isEntitled)
        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(store.unlockSource, .license)
        XCTAssertEqual(settingsStore.settings.proLicenseBlob, blob)
        // Install stamps last-verified with the injected clock, exactly.
        XCTAssertEqual(settingsStore.settings.proLicenseLastVerifiedAt, pinned)
    }

    @MainActor
    func testInstallRejectedLicensePersistsNothing() throws {
        let settingsStore = makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            now: { pinned }
        )

        // Expired at install time: rejected with the expired reason, and
        // settings stay untouched — no installed-but-dead license at rest.
        let expired = try signedBlob(makePayload(expiresAt: now.addingTimeInterval(-1)))
        let result = store.installLicense(expired)

        guard case .denied(.expired) = result else {
            return XCTFail("expected an expired denial, got \(result)")
        }
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertNil(settingsStore.settings.proLicenseBlob)
        XCTAssertNil(settingsStore.settings.proLicenseLastVerifiedAt)
    }

    @MainActor
    func testDeveloperOverrideStillUnlocksWithoutALicense() {
        let settingsStore = makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            now: { pinned }
        )

        var settings = settingsStore.settings
        settings.proUnlockOverrideEnabled = true
        store.applySettings(settings)

        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(store.unlockSource, .developerOverride)
    }

    /// Sentry Pro is one product: every `ProFeature` case must answer the
    /// entitlement question identically — locked denies all, a license or
    /// the override unlocks all. Iterating `allCases` means a feature added
    /// to the enum joins this assertion automatically, so a future
    /// per-feature carve-out has to be a deliberate edit here, not a drift.
    @MainActor
    func testEveryProFeatureAnswersIdenticallyUnderEveryUnlockSource() throws {
        let settingsStore = makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            now: { pinned }
        )

        for feature in ProFeature.allCases {
            XCTAssertFalse(store.isUnlocked(feature), "locked must deny \(feature)")
        }

        var settings = settingsStore.settings
        settings.proUnlockOverrideEnabled = true
        store.applySettings(settings)
        for feature in ProFeature.allCases {
            XCTAssertTrue(store.isUnlocked(feature), "override must unlock \(feature)")
        }

        settings.proUnlockOverrideEnabled = false
        store.applySettings(settings)
        store.installLicense(try signedBlob(makePayload()))
        for feature in ProFeature.allCases {
            XCTAssertTrue(store.isUnlocked(feature), "a license must unlock \(feature)")
        }
    }

    /// Same parity contract for the override-only reference conformer.
    @MainActor
    func testReferenceStoreAnswersEveryFeatureIdenticallyToo() {
        let settingsStore = makeSettingsStore()
        let store = ProEntitlementStore(settingsStore: settingsStore)

        for feature in ProFeature.allCases {
            XCTAssertFalse(store.isUnlocked(feature), "locked must deny \(feature)")
        }
        store.setDeveloperOverride(true)
        for feature in ProFeature.allCases {
            XCTAssertTrue(store.isUnlocked(feature), "override must unlock \(feature)")
        }
    }

    /// Every paid feature must be able to say what it is on a locked
    /// screen — same no-empty-strings rule `LicenseDenialReason` follows.
    func testEveryProFeatureHasDisplayCopy() {
        for feature in ProFeature.allCases {
            XCTAssertFalse(feature.displayName.isEmpty, "\(feature)")
            XCTAssertFalse(feature.summary.isEmpty, "\(feature)")
        }
    }

    @MainActor
    func testLicenseOutranksOverrideAsTheReportedSource() throws {
        let settingsStore = makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            now: { pinned }
        )

        var settings = settingsStore.settings
        settings.proUnlockOverrideEnabled = true
        store.applySettings(settings)
        store.installLicense(try signedBlob(makePayload()))

        // Both hold; the attribution is the stronger claim.
        XCTAssertEqual(store.unlockSource, .license)
    }

    @MainActor
    func testRemoveLicenseLocksAgainAndClearsPersistence() throws {
        let settingsStore = makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            now: { pinned }
        )
        store.installLicense(try signedBlob(makePayload()))
        XCTAssertTrue(store.isUnlocked(.protectionInsights))

        store.removeLicense()

        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(store.unlockSource, .locked)
        XCTAssertEqual(store.decision, .denied(.noLicense))
        XCTAssertNil(settingsStore.settings.proLicenseBlob)
        XCTAssertNil(settingsStore.settings.proLicenseLastVerifiedAt)
    }

    @MainActor
    func testStoreSeededFromSettingsEntitlesOnRelaunch() throws {
        // Simulates a relaunch: the blob is already in settings when the
        // store is constructed.
        let settingsStore = makeSettingsStore()
        let blob = try signedBlob(makePayload())
        settingsStore.settings.proLicenseBlob = blob
        settingsStore.settings.proLicenseLastVerifiedAt = now.addingTimeInterval(-1 * day)

        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            now: { pinned }
        )

        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(store.unlockSource, .license)
    }

    @MainActor
    func testStaleRevalidationUnderGracePolicyLocksWithTheLapsedReason() throws {
        let settingsStore = makeSettingsStore()
        let blob = try signedBlob(makePayload())
        let stale = now.addingTimeInterval(-30 * day)
        settingsStore.settings.proLicenseBlob = blob
        settingsStore.settings.proLicenseLastVerifiedAt = stale

        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            revalidationPolicy: LicenseRevalidationPolicy(graceWindow: 14 * day),
            now: { pinned }
        )

        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(
            store.decision,
            .denied(.revalidationLapsed(lastVerifiedAt: stale, graceWindow: 14 * day))
        )
    }

    @MainActor
    func testKeylessBuildWithAnInstalledBlobSaysWhyPlainly() throws {
        // The shipping configuration today: no production key embedded.
        let settingsStore = makeSettingsStore()
        settingsStore.settings.proLicenseBlob = try signedBlob(makePayload())

        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: nil,
            now: { pinned }
        )

        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(store.decision, .denied(.verificationUnavailableInThisBuild))
        XCTAssertFalse(LicenseDenialReason.verificationUnavailableInThisBuild.explanation.isEmpty)
    }

    // MARK: - The activation seam

    /// TEST-ONLY stub. Deliberately the only `LicenseActivationClient`
    /// conformer in the entire repository — see `LicenseActivation.swift`
    /// for why no concrete network client exists.
    private struct StubActivationClient: LicenseActivationClient {
        var blobToReturn: String = ""
        var revalidationOutcome: LicenseRevalidationOutcome = .stillValid(refreshedBlob: nil)

        func activate(licenseKey: String) async throws -> String { blobToReturn }
        func revalidate(licenseID: String) async throws -> LicenseRevalidationOutcome { revalidationOutcome }
    }

    @MainActor
    func testActivateWithoutABackendThrowsTheHonestError() async {
        let settingsStore = makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            activationClient: nil,
            now: { pinned }
        )

        do {
            _ = try await store.activate(licenseKey: "SENTRY-XXXX-YYYY")
            XCTFail("activation with no backend must throw")
        } catch let error as LicenseActivationError {
            XCTAssertEqual(error, .noActivationBackendConfigured)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
    }

    @MainActor
    func testActivateVerifiesTheServerBlobLocallyBeforeInstalling() async throws {
        let settingsStore = makeSettingsStore()
        let pinned = now

        // A well-behaved server returning a genuine blob: installed.
        let goodBlob = try signedBlob(makePayload())
        let goodStore = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            activationClient: StubActivationClient(blobToReturn: goodBlob),
            now: { pinned }
        )
        let payload = try await goodStore.activate(licenseKey: "SENTRY-XXXX-YYYY")
        XCTAssertEqual(payload.emailSHA256, LicensePayload.emailHash("buyer@example.com"))
        XCTAssertTrue(goodStore.isUnlocked(.protectionInsights))

        // A misbehaving server returning a blob signed by the wrong key:
        // rejected locally, nothing installed. TEST-ONLY key again.
        let forgedBlob = try signedBlob(makePayload(), key: Curve25519.Signing.PrivateKey())
        let otherSettings = makeSettingsStore()
        let wary = LicenseProEntitlementStore(
            settingsStore: otherSettings,
            publicKey: testKey.publicKey,
            activationClient: StubActivationClient(blobToReturn: forgedBlob),
            now: { pinned }
        )
        do {
            _ = try await wary.activate(licenseKey: "SENTRY-XXXX-YYYY")
            XCTFail("a server blob that fails local verification must throw")
        } catch let error as LicenseActivationError {
            XCTAssertEqual(error, .serverReturnedInvalidLicense(.signatureInvalid))
        }
        XCTAssertFalse(wary.isUnlocked(.protectionInsights))
        XCTAssertNil(otherSettings.settings.proLicenseBlob)
    }

    @MainActor
    func testRevalidateStillValidRefreshesTheTimestampAndRestoresEntitlement() async throws {
        // Grace has lapsed; the server vouches; entitlement returns and the
        // timestamp is stamped with the pinned clock.
        let settingsStore = makeSettingsStore()
        let blob = try signedBlob(makePayload())
        settingsStore.settings.proLicenseBlob = blob
        settingsStore.settings.proLicenseLastVerifiedAt = now.addingTimeInterval(-30 * day)

        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            activationClient: StubActivationClient(revalidationOutcome: .stillValid(refreshedBlob: nil)),
            revalidationPolicy: LicenseRevalidationPolicy(graceWindow: 14 * day),
            now: { pinned }
        )
        XCTAssertFalse(store.isUnlocked(.protectionInsights))

        try await store.revalidate()

        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(settingsStore.settings.proLicenseLastVerifiedAt, pinned)
    }

    @MainActor
    func testRevalidateRevokedRemovesTheLicense() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.proLicenseBlob = try signedBlob(makePayload())
        settingsStore.settings.proLicenseLastVerifiedAt = now.addingTimeInterval(-1 * day)

        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            activationClient: StubActivationClient(revalidationOutcome: .revoked(reason: "refunded")),
            now: { pinned }
        )
        XCTAssertTrue(store.isUnlocked(.protectionInsights))

        try await store.revalidate()

        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertNil(settingsStore.settings.proLicenseBlob)
        XCTAssertEqual(store.decision, .denied(.noLicense))
    }
}
