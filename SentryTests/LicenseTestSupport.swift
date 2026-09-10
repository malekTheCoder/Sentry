import CryptoKit
import Foundation
@testable import SentryKit

/// Shared helpers for the license tests that exercise the *seam* — the
/// activation model, the scheduler — rather than the crypto.
///
/// **Every key minted through here is TEST-ONLY** and generated at runtime;
/// nothing signed with one can ever verify against the (absent) production
/// key. **Every date is pinned**: `pinnedNow` is the one instant, and every
/// store built here takes a clock closure returning it, so no assertion
/// races the wall clock. Same discipline as `LicenseProEntitlementTests`,
/// which keeps its own private copies of these because it predates this
/// file and its tests are the reference for the pure functions.
enum LicenseTestSupport {

    static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
    static let day: TimeInterval = 24 * 3600

    static func payload(
        licenseID: String = "9C1B2A6E-0000-4000-8000-DEADBEEF0002",
        email: String = "buyer@example.com",
        seats: Int = 3,
        issuedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> LicensePayload {
        LicensePayload(
            licenseID: licenseID,
            emailSHA256: LicensePayload.emailHash(email),
            seats: seats,
            issuedAt: Int((issuedAt ?? pinnedNow.addingTimeInterval(-30 * day)).timeIntervalSince1970),
            expiresAt: expiresAt.map { Int($0.timeIntervalSince1970) }
        )
    }

    /// Signs exactly the way the real issuing side must: encode, sign
    /// those bytes, compose. `key` is whichever TEST-ONLY key the caller
    /// minted — passing a different one than the store verifies with is
    /// how the wrong-key cases are built.
    static func signedBlob(_ payload: LicensePayload, key: Curve25519.Signing.PrivateKey) throws -> String {
        let json = try JSONEncoder().encode(payload)
        let signature = try key.signature(for: json)
        return SignedLicense.compose(payloadJSON: json, signature: signature)
    }

    /// A `SettingsStore` on a throwaway URL with a debounce long enough that
    /// no test ever races a disk write.
    static func makeSettingsStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("license-ui-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        return SettingsStore(fileURL: url, debounceInterval: 3600)
    }
}

/// TEST-ONLY `LicenseActivationClient`. Together with the private stub in
/// `LicenseProEntitlementTests`, the only conformers in the repository —
/// both under `SentryTests/`, neither performing network IO. See
/// `LicenseActivation.swift` for why no concrete client exists; Part 5b
/// writes it once a vendor is chosen.
///
/// A class (not a struct) so the scheduler tests can count calls made from
/// a background loop; the lock is what makes the `@unchecked Sendable`
/// honest.
final class StubLicenseActivationClient: LicenseActivationClient, @unchecked Sendable {

    enum ActivateBehavior {
        case returnBlob(String)
        case throwError(Error)
    }

    enum RevalidateBehavior {
        case answer(LicenseRevalidationOutcome)
        case throwError(Error)
    }

    private let lock = NSLock()
    private var _activateCalls: [String] = []
    private var _revalidateCalls: [String] = []

    var activateBehavior: ActivateBehavior
    var revalidateBehavior: RevalidateBehavior

    init(
        activate: ActivateBehavior = .throwError(StubActivationError(message: "activate not configured")),
        revalidate: RevalidateBehavior = .answer(.stillValid(refreshedBlob: nil))
    ) {
        self.activateBehavior = activate
        self.revalidateBehavior = revalidate
    }

    var activateCalls: [String] { lock.withLock { _activateCalls } }
    var revalidateCalls: [String] { lock.withLock { _revalidateCalls } }

    func activate(licenseKey: String) async throws -> String {
        lock.withLock { _activateCalls.append(licenseKey) }
        switch activateBehavior {
        case .returnBlob(let blob): return blob
        case .throwError(let error): throw error
        }
    }

    func revalidate(licenseID: String) async throws -> LicenseRevalidationOutcome {
        lock.withLock { _revalidateCalls.append(licenseID) }
        switch revalidateBehavior {
        case .answer(let outcome): return outcome
        case .throwError(let error): throw error
        }
    }
}

/// Stands in for whatever a concrete client will throw when the *server*
/// says no — an unknown key, a revoked key. The protocol leaves that type
/// to the conformer; what the UI can rely on is `localizedDescription`.
struct StubActivationError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}
