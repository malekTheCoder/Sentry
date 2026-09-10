import CryptoKit
import XCTest
@testable import Sentry
@testable import SentryKit

/// The state machine behind Settings ▸ Sentry Pro
/// (`Sentry/Settings/ProLicenseActivationModel.swift`) and the pure copy
/// on `ProLicensePane`, driven end to end with a TEST-ONLY key and the
/// TEST-ONLY `StubLicenseActivationClient` — no SwiftUI, no network.
///
/// What these defend: that a pasted license activates offline with no
/// backend at all; that every way activation can fail (bad blob, wrong
/// key, key-with-no-backend, server rejection, transport failure, server
/// returning a forgery) lands in a typed case with a sentence and leaves
/// the Mac unchanged; and that removal really removes.
@MainActor
final class ProLicenseActivationModelTests: XCTestCase {

    private let testKey = Curve25519.Signing.PrivateKey()
    private let now = LicenseTestSupport.pinnedNow

    private func makeStore(
        settings: SettingsStore? = nil,
        client: StubLicenseActivationClient? = nil,
        policy: LicenseRevalidationPolicy = .never
    ) -> (LicenseProEntitlementStore, SettingsStore) {
        let settingsStore = settings ?? LicenseTestSupport.makeSettingsStore()
        let pinned = now
        let store = LicenseProEntitlementStore(
            settingsStore: settingsStore,
            publicKey: testKey.publicKey,
            activationClient: client,
            revalidationPolicy: policy,
            now: { pinned }
        )
        return (store, settingsStore)
    }

    private func goodBlob(seats: Int = 3) throws -> String {
        try LicenseTestSupport.signedBlob(LicenseTestSupport.payload(seats: seats), key: testKey)
    }

    // MARK: - Classification

    func testClassifyRoutesBlobsKeysAndBlanks() throws {
        XCTAssertEqual(ProLicenseActivationModel.classify(""), .empty)
        XCTAssertEqual(ProLicenseActivationModel.classify("  \n\t "), .empty)

        let blob = try goodBlob()
        // Surrounding whitespace is how pasted text arrives; it is trimmed
        // before classification so the blob case sees the blob.
        XCTAssertEqual(ProLicenseActivationModel.classify("  \(blob)\n"), .signedBlob(blob))
        // A future format is still "a license", not a key — routing it to
        // installLicense is what yields the honest .unsupportedFormat.
        XCTAssertEqual(ProLicenseActivationModel.classify("sentry-pro-v2.a.b"), .signedBlob("sentry-pro-v2.a.b"))

        XCTAssertEqual(ProLicenseActivationModel.classify("SENTRY-1234-5678-9ABC"), .licenseKey("SENTRY-1234-5678-9ABC"))
    }

    // MARK: - The paste-a-license path (works with no vendor at all)

    func testPastedBlobActivatesOfflineWithNoBackend() async throws {
        let (store, settings) = makeStore(client: nil)
        let model = ProLicenseActivationModel(store: store)
        XCTAssertFalse(model.hasActivationBackend)
        XCTAssertFalse(store.isUnlocked(.protectionInsights))

        let blob = try goodBlob(seats: 3)
        model.input = "  \(blob)\n"   // sloppy paste, per dry-run step 6
        XCTAssertTrue(model.canSubmit)
        await model.submit()

        guard case .activated(let payload) = model.phase else {
            return XCTFail("expected .activated, got \(model.phase)")
        }
        XCTAssertEqual(payload.seats, 3)
        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(store.unlockSource, .license)
        XCTAssertEqual(settings.settings.proLicenseBlob, blob)
        XCTAssertEqual(settings.settings.proLicenseLastVerifiedAt, now)
        // The field is cleared on success so the blob isn't left sitting
        // in an editable control; the store has it now.
        XCTAssertEqual(model.input, "")
        XCTAssertTrue(model.hasInstalledLicense)
    }

    func testBlobSignedByTheWrongKeyIsRejectedWithTheDenialSentenceAndPersistsNothing() async throws {
        let (store, settings) = makeStore()
        let model = ProLicenseActivationModel(store: store)

        // TEST-ONLY second key: someone else's signature.
        let forged = try LicenseTestSupport.signedBlob(LicenseTestSupport.payload(), key: Curve25519.Signing.PrivateKey())
        model.input = forged
        await model.submit()

        XCTAssertEqual(model.phase, .failed(.rejected(.signatureInvalid)))
        if case .failed(let failure) = model.phase {
            XCTAssertEqual(failure.message, LicenseDenialReason.signatureInvalid.explanation)
        }
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertNil(settings.settings.proLicenseBlob)
        // The text stays in the field: the user may want to re-copy and
        // compare, and clearing it would destroy the only evidence.
        XCTAssertEqual(model.input, forged)
    }

    func testMangledPasteIsRejectedAsMalformed() async {
        let (store, _) = makeStore()
        let model = ProLicenseActivationModel(store: store)
        model.input = "sentry-pro-v1.this-got-truncated"
        await model.submit()

        guard case .failed(.rejected(.malformed)) = model.phase else {
            return XCTFail("expected .malformed, got \(model.phase)")
        }
        XCTAssertFalse(store.hasInstalledLicense)
    }

    func testExpiredBlobIsRejectedWithItsDate() async throws {
        let (store, _) = makeStore()
        let model = ProLicenseActivationModel(store: store)
        let expiry = now.addingTimeInterval(-LicenseTestSupport.day)
        model.input = try LicenseTestSupport.signedBlob(LicenseTestSupport.payload(expiresAt: expiry), key: testKey)
        await model.submit()

        guard case .failed(.rejected(.expired(let on))) = model.phase else {
            return XCTFail("expected .expired, got \(model.phase)")
        }
        XCTAssertEqual(on, Date(timeIntervalSince1970: TimeInterval(Int(expiry.timeIntervalSince1970))))
        XCTAssertFalse(store.hasInstalledLicense)
    }

    // MARK: - The key path without a backend (this build)

    func testKeyWithoutBackendExplainsWhatToPasteInsteadAndTouchesNothing() async {
        let (store, settings) = makeStore(client: nil)
        let model = ProLicenseActivationModel(store: store)
        model.input = "SENTRY-1234-5678-9ABC"
        await model.submit()

        XCTAssertEqual(model.phase, .failed(.keyNeedsBackend))
        if case .failed(let failure) = model.phase {
            XCTAssertTrue(failure.message.contains("sentry-pro-v1"), "the sentence must name what to paste instead")
        }
        XCTAssertNil(settings.settings.proLicenseBlob)
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
    }

    // MARK: - The key path with a (stub) backend

    func testKeyWithBackendActivatesViaTheClient() async throws {
        let blob = try goodBlob()
        let client = StubLicenseActivationClient(activate: .returnBlob(blob))
        let (store, settings) = makeStore(client: client)
        let model = ProLicenseActivationModel(store: store)
        XCTAssertTrue(model.hasActivationBackend)

        model.input = "SENTRY-1234-5678-9ABC"
        await model.submit()

        XCTAssertEqual(client.activateCalls, ["SENTRY-1234-5678-9ABC"])
        guard case .activated = model.phase else {
            return XCTFail("expected .activated, got \(model.phase)")
        }
        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(settings.settings.proLicenseBlob, blob)
        XCTAssertEqual(model.input, "")
    }

    /// A key the server doesn't honor — unknown, or revoked after a refund.
    /// The protocol leaves the error type to the conformer; the UI shows
    /// its description and, critically, changes nothing locally.
    func testKeyRejectedByTheServerSurfacesTheReasonAndChangesNothing() async {
        let client = StubLicenseActivationClient(
            activate: .throwError(StubActivationError(message: "This license key has been revoked."))
        )
        let (store, settings) = makeStore(client: client)
        let model = ProLicenseActivationModel(store: store)
        model.input = "SENTRY-REVOKED-KEY"
        await model.submit()

        XCTAssertEqual(model.phase, .failed(.activationFailed("This license key has been revoked.")))
        if case .failed(let failure) = model.phase {
            XCTAssertTrue(failure.message.contains("This license key has been revoked."))
            XCTAssertTrue(failure.message.contains("Nothing on this Mac was changed"))
        }
        XCTAssertNil(settings.settings.proLicenseBlob)
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
    }

    func testNetworkFailureDuringActivationLeavesTheMacUnchanged() async {
        let client = StubLicenseActivationClient(
            activate: .throwError(URLError(.notConnectedToInternet))
        )
        let (store, settings) = makeStore(client: client)
        let model = ProLicenseActivationModel(store: store)
        model.input = "SENTRY-1234-5678-9ABC"
        await model.submit()

        guard case .failed(.activationFailed(let description)) = model.phase else {
            return XCTFail("expected .activationFailed, got \(model.phase)")
        }
        XCTAssertFalse(description.isEmpty)
        XCTAssertNil(settings.settings.proLicenseBlob)
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        // Not stuck in `.working`: the button must come back.
        XCTAssertTrue(model.canSubmit)
    }

    /// A server response is input, not authority — the same principle
    /// `testActivateVerifiesTheServerBlobLocallyBeforeInstalling` pins on
    /// the store, seen from the UI: the failure is its own case with its
    /// own sentence, and nothing is installed.
    func testServerReturningAForgeryIsRefusedWithItsOwnSentence() async throws {
        let forged = try LicenseTestSupport.signedBlob(LicenseTestSupport.payload(), key: Curve25519.Signing.PrivateKey())
        let client = StubLicenseActivationClient(activate: .returnBlob(forged))
        let (store, settings) = makeStore(client: client)
        let model = ProLicenseActivationModel(store: store)
        model.input = "SENTRY-1234-5678-9ABC"
        await model.submit()

        XCTAssertEqual(model.phase, .failed(.serverReturnedInvalidLicense(.signatureInvalid)))
        if case .failed(let failure) = model.phase {
            XCTAssertTrue(failure.message.contains("was not installed"))
        }
        XCTAssertNil(settings.settings.proLicenseBlob)
    }

    // MARK: - Removal

    func testRemoveLicenseLocksImmediatelyAndClearsPersistence() async throws {
        let (store, settings) = makeStore()
        let model = ProLicenseActivationModel(store: store)
        model.input = try goodBlob()
        await model.submit()
        XCTAssertTrue(store.isUnlocked(.protectionInsights))
        XCTAssertTrue(model.hasInstalledLicense)

        model.removeLicense()

        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertEqual(store.unlockSource, .locked)
        XCTAssertEqual(store.decision, .denied(.noLicense))
        XCTAssertNil(settings.settings.proLicenseBlob)
        XCTAssertNil(settings.settings.proLicenseLastVerifiedAt)
        XCTAssertFalse(model.hasInstalledLicense)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.input, "")
    }

    /// The store's `hasInstalledLicense` is about the blob, not the
    /// decision: a blob this build can't honor must still be removable.
    func testAnUnhonoredLicenseIsStillRemovable() throws {
        let settings = LicenseTestSupport.makeSettingsStore()
        settings.settings.proLicenseBlob = try goodBlob()
        // Keyless build: the blob is installed but denied with the build gap.
        let pinned = now
        let store = LicenseProEntitlementStore(settingsStore: settings, publicKey: nil, now: { pinned })
        XCTAssertEqual(store.decision, .denied(.verificationUnavailableInThisBuild))
        XCTAssertTrue(store.hasInstalledLicense)

        let model = ProLicenseActivationModel(store: store)
        model.removeLicense()
        XCTAssertFalse(store.hasInstalledLicense)
        XCTAssertNil(settings.settings.proLicenseBlob)
    }

    // MARK: - Confirm with server (manual revalidation)

    func testConfirmStillValidReportsConfirmedAndRefreshesTheStamp() async throws {
        let settings = LicenseTestSupport.makeSettingsStore()
        settings.settings.proLicenseBlob = try goodBlob()
        settings.settings.proLicenseLastVerifiedAt = now.addingTimeInterval(-3 * LicenseTestSupport.day)
        let client = StubLicenseActivationClient(revalidate: .answer(.stillValid(refreshedBlob: nil)))
        let (store, _) = makeStore(settings: settings, client: client, policy: .standard)
        let model = ProLicenseActivationModel(store: store)

        await model.confirmWithServer()

        XCTAssertEqual(model.phase, .confirmed)
        XCTAssertEqual(client.revalidateCalls, [LicenseTestSupport.payload().licenseID])
        XCTAssertEqual(settings.settings.proLicenseLastVerifiedAt, now)
        XCTAssertEqual(model.lastVerifiedDate, now)
    }

    func testConfirmRevokedRemovesTheLicenseAndSaysWhy() async throws {
        let settings = LicenseTestSupport.makeSettingsStore()
        settings.settings.proLicenseBlob = try goodBlob()
        settings.settings.proLicenseLastVerifiedAt = now
        let client = StubLicenseActivationClient(revalidate: .answer(.revoked(reason: "refunded")))
        let (store, _) = makeStore(settings: settings, client: client, policy: .standard)
        let model = ProLicenseActivationModel(store: store)
        XCTAssertTrue(store.isUnlocked(.protectionInsights))

        await model.confirmWithServer()

        XCTAssertEqual(model.phase, .failed(.revokedByServer("refunded")))
        if case .failed(let failure) = model.phase {
            XCTAssertTrue(failure.message.contains("refunded"))
        }
        XCTAssertFalse(store.isUnlocked(.protectionInsights))
        XCTAssertNil(settings.settings.proLicenseBlob)
        XCTAssertFalse(model.hasInstalledLicense)
    }

    func testConfirmWithoutBackendIsRefusedNotAttempted() async {
        let (store, _) = makeStore(client: nil)
        let model = ProLicenseActivationModel(store: store)
        await model.confirmWithServer()
        XCTAssertEqual(model.phase, .failed(.keyNeedsBackend))
    }

    // MARK: - Submit gating

    func testCanSubmitIsFalseForBlankInput() {
        let (store, _) = makeStore()
        let model = ProLicenseActivationModel(store: store)
        XCTAssertFalse(model.canSubmit)
        model.input = "   "
        XCTAssertFalse(model.canSubmit)
        model.input = "anything"
        XCTAssertTrue(model.canSubmit)
    }

    // MARK: - Every failure has on-screen language

    func testEveryFailureHasASentence() {
        let failures: [ProLicenseActivationModel.Failure] = [
            .rejected(.noLicense),
            .rejected(.signatureInvalid),
            .rejected(.malformed(reason: "x")),
            .rejected(.unsupportedFormat(prefix: "sentry-pro-v9")),
            .rejected(.expired(on: now)),
            .rejected(.verificationUnavailableInThisBuild),
            .rejected(.revalidationLapsed(lastVerifiedAt: nil, graceWindow: 1)),
            .keyNeedsBackend,
            .serverReturnedInvalidLicense(.signatureInvalid),
            .activationFailed("boom"),
            .revokedByServer("refunded"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no sentence")
        }
    }

    // MARK: - Pane copy (pure)

    func testStatusHeadlinesDistinguishEveryState() throws {
        let payload = LicenseTestSupport.payload()
        let entitled = ProLicensePane.statusHeadline(for: .entitled(payload), unlockSource: .license)
        let none = ProLicensePane.statusHeadline(for: .denied(.noLicense), unlockSource: .locked)
        let override = ProLicensePane.statusHeadline(for: .denied(.noLicense), unlockSource: .developerOverride)
        let broken = ProLicensePane.statusHeadline(for: .denied(.signatureInvalid), unlockSource: .locked)

        XCTAssertTrue(entitled.contains("active"))
        XCTAssertTrue(none.localizedCaseInsensitiveContains("no license"))
        // The override must never read as a license (`ProUnlockSource`'s
        // whole reason for existing).
        XCTAssertTrue(override.localizedCaseInsensitiveContains("developer override"))
        XCTAssertNotEqual(none, override)
        XCTAssertNotEqual(broken, none)
        XCTAssertEqual(Set([entitled, none, override, broken]).count, 4)
    }

    func testActivationCaptionOffersOnlyThePathThatWorks() {
        let offline = ProLicensePane.activationCaption(hasActivationBackend: false)
        let online = ProLicensePane.activationCaption(hasActivationBackend: true)

        XCTAssertTrue(offline.contains("sentry-pro-v1"))
        XCTAssertFalse(offline.localizedCaseInsensitiveContains("license key"), "with no backend the caption may not invite a key")
        XCTAssertTrue(offline.localizedCaseInsensitiveContains("no internet"))

        XCTAssertTrue(online.localizedCaseInsensitiveContains("license key"))
        XCTAssertTrue(online.localizedCaseInsensitiveContains("server"))
    }

    func testExpiryLabelSaysNeverForAPerpetualLicense() {
        XCTAssertTrue(ProLicensePane.expiryLabel(LicenseTestSupport.payload(expiresAt: nil)).localizedCaseInsensitiveContains("never"))
        let dated = ProLicensePane.expiryLabel(LicenseTestSupport.payload(expiresAt: now.addingTimeInterval(365 * LicenseTestSupport.day)))
        XCTAssertFalse(dated.localizedCaseInsensitiveContains("never"))
    }

    func testSeatsLabelPluralizes() {
        XCTAssertEqual(ProLicensePane.seatsLabel(1), "1 Mac")
        XCTAssertEqual(ProLicensePane.seatsLabel(3), "3 Macs")
    }

    /// No `deactivate` exists on the seam, so the removal copy may not
    /// claim a seat is freed anywhere but this Mac.
    func testRemovalCopyPromisesOnlyWhatHappensLocally() {
        for text in [ProLicensePane.removalCaption, ProLicensePane.removalDialogMessage] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains("this Mac"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("seat"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("server"))
        }
    }
}
