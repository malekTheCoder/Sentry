import CryptoKit
import Foundation

// MARK: - The Sentry Pro license: format, verification, and entitlement policy
//
// This file is the *verification* half of the license system: everything
// needed to decide, offline and deterministically, whether a pasted-in
// license blob is genuine. The *issuance* half — the private signing key,
// the checkout webhook that mints blobs, the activation server — lives
// nowhere in this repository, on purpose: Sentry ships via Developer ID
// outside the Mac App Store, so the earlier doc comments prescribing
// StoreKit described an implementation that cannot exist (in-app purchase
// requires Mac App Store distribution), and the replacement — a
// Paddle/Lemon Squeezy-style checkout — requires a merchant account only
// the project owner can create. `LicenseActivationClient`
// (`LicenseActivation.swift`) is the seam that side plugs into; nothing in
// this file performs network IO.
//
// Everything here is pure: functions of (blob, key, dates) → values, with
// every date passed in explicitly. That is what makes the license logic
// testable with pinned dates and keeps `Date()` out of assertions — the
// same discipline `ProtectionInsightsEngineTests` applies to insight rules.

/// The payload a license blob carries, once its signature has checked out.
///
/// **Fields, and why these fields:**
/// - `licenseID`: a UUID string minted at purchase. The stable handle a
///   future activation/revalidation call names the license by — the blob
///   itself is too long to be a good primary key, and the email hash is
///   deliberately not unique (one person can buy twice).
/// - `emailSHA256`: hex SHA-256 of the buyer's email, trimmed and
///   lowercased (see `emailHash(_:)` — one normalization, both sides).
///   A *hash* rather than the email itself so the license file sitting in
///   `settings.json` — a file users paste into bug reports — never
///   contains the address in the clear. Enough for support to confirm "this
///   license was sold to you" given the address; not enough for anyone
///   holding the blob to learn it.
/// - `seats`: how many Macs the purchase covers. Carried in the payload so
///   the app can *display* it honestly; **not enforced client-side**, and
///   that is deliberate — seat enforcement requires a server that counts
///   activations (the `LicenseActivationClient` seam), and a client-side
///   guess at "how many other Macs is this blob on?" would be exactly the
///   kind of fabricated reading this codebase refuses to make.
/// - `issuedAt` / `expiresAt`: epoch seconds (integers, not doubles — a
///   canonical wire format shouldn't depend on float formatting).
///   `expiresAt == nil` means **perpetual**: nil-versus-value is the
///   type-system distinction between "never expires" and "expires at T",
///   never a magic sentinel date.
public struct LicensePayload: Codable, Equatable, Sendable {
    public var licenseID: String
    public var emailSHA256: String
    public var seats: Int
    /// Epoch seconds.
    public var issuedAt: Int
    /// Epoch seconds, or nil for a perpetual license.
    public var expiresAt: Int?

    public init(licenseID: String, emailSHA256: String, seats: Int, issuedAt: Int, expiresAt: Int?) {
        self.licenseID = licenseID
        self.emailSHA256 = emailSHA256
        self.seats = seats
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public var issuedDate: Date { Date(timeIntervalSince1970: TimeInterval(issuedAt)) }
    public var expiryDate: Date? { expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var isPerpetual: Bool { expiresAt == nil }

    /// The one email normalization both the issuing side and any support
    /// flow must share: trim whitespace, lowercase, SHA-256, lowercase hex.
    /// Kept here — next to the field it feeds — so the two sides can't
    /// drift into hashing subtly different strings.
    public static func emailHash(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The license blob: parsing, composing, and Ed25519 verification.
///
/// **Wire format (the string a buyer receives and pastes in):**
///
///     sentry-pro-v1.<base64url(payload JSON)>.<base64url(signature)>
///
/// Three dot-separated segments. The first is a fixed, human-readable
/// prefix so a blob is recognizable in a support email and so a future
/// incompatible layout can ship as `sentry-pro-v2` without ambiguity. The
/// second is the UTF-8 JSON encoding of `LicensePayload`, base64url. The
/// third is a 64-byte Ed25519 signature — over **the exact payload bytes
/// of segment two**, not over a re-encoding — base64url. Base64url without
/// padding (`-`/`_`, no `=`) because the blob travels through email and
/// chat, where `+`, `/`, and trailing `=` invite word-wrap and
/// double-click-selection mangling.
///
/// **Why sign the transmitted bytes rather than a canonicalized JSON.**
/// JSON has no single canonical form — key order, whitespace, and number
/// formatting all vary by encoder — and every signing scheme that verifies
/// a *re-serialization* of parsed JSON eventually breaks when the two
/// sides' encoders disagree. Signing the exact bytes carried in the blob
/// sidesteps the entire problem: verification checks the signature against
/// segment two as received, and only then parses those same bytes. The
/// issuing side may serialize its JSON however it likes.
///
/// **Why Ed25519.** Small keys (32-byte public), small signatures
/// (64 bytes), no parameter choices to get wrong, misuse-resistant by
/// design, and CryptoKit ships it on every OS this app supports — no
/// dependency, no OpenSSL. The public key embeds in the binary; the
/// private key never comes anywhere near this repository (see
/// `LicenseKeys`).
public enum SignedLicense {

    /// Segment one, verbatim. A blob with any other prefix is
    /// `.unsupportedFormat` — an honest "this build doesn't speak that
    /// version", distinct from "corrupt".
    public static let blobPrefix = "sentry-pro-v1"

    /// Every distinguishable outcome of looking at a blob. `expired` is
    /// its own case, carrying the parsed payload, rather than a flavor of
    /// invalid: an expired license is *genuine* — the honest message is
    /// "this expired on March 3rd", which requires the payload, and is a
    /// different situation from "this blob is forged" in every way a user
    /// cares about.
    public enum Verification: Equatable, Sendable {
        case valid(LicensePayload)
        case expired(LicensePayload, expiredAt: Date)
        /// The signature does not match the payload under the given key —
        /// tampered payload, wrong key, or truncated signature all land
        /// here. Deliberately not subdivided further: distinguishing
        /// "tampered" from "signed by someone else" is cryptographically
        /// meaningless to the verifier.
        case signatureInvalid
        /// Structurally broken: wrong segment count, undecodable base64,
        /// payload that isn't `LicensePayload` JSON. The reason string is
        /// for support/logs, not a security oracle — it never echoes blob
        /// content.
        case malformed(reason: String)
        /// Parsed enough to see a prefix this build doesn't speak.
        case unsupportedFormat(prefix: String)
    }

    /// The whole verification, as a pure function.
    ///
    /// Order matters and is deliberate: structure first (malformed /
    /// unsupported), then signature, then expiry — so `.expired` is only
    /// ever reported for a blob that *proved* it was issued by us. An
    /// attacker learns nothing from expiry handling with a forged blob;
    /// they just get `.signatureInvalid`.
    ///
    /// - Parameter now: passed in, never sampled here — expiry is a
    ///   comparison against a caller-supplied instant so tests pin it.
    public static func verify(
        blob: String,
        publicKey: Curve25519.Signing.PublicKey,
        at now: Date
    ) -> Verification {
        let segments = blob
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)

        guard segments.count == 3 else {
            return .malformed(reason: "expected 3 dot-separated segments, found \(segments.count)")
        }
        guard segments[0] == blobPrefix else {
            return .unsupportedFormat(prefix: segments[0])
        }
        guard let payloadData = base64URLDecode(segments[1]) else {
            return .malformed(reason: "payload segment is not valid base64url")
        }
        guard let signature = base64URLDecode(segments[2]) else {
            return .malformed(reason: "signature segment is not valid base64url")
        }

        // Signature over the exact transmitted payload bytes — see the type
        // doc comment on why no re-encoding is ever verified.
        guard publicKey.isValidSignature(signature, for: payloadData) else {
            return .signatureInvalid
        }

        let payload: LicensePayload
        do {
            payload = try JSONDecoder().decode(LicensePayload.self, from: payloadData)
        } catch {
            // Signed by us, but not a payload this build can read — in
            // practice a future schema signed by the same key. Malformed,
            // not signatureInvalid: the crypto was fine.
            return .malformed(reason: "payload JSON did not decode as a license payload")
        }

        if let expiry = payload.expiryDate, now >= expiry {
            // `>=`: the license is good strictly *until* its expiry
            // instant. At the instant itself it is expired — the honest
            // reading of "expires at", and the boundary the tests pin.
            return .expired(payload, expiredAt: expiry)
        }

        return .valid(payload)
    }

    /// Assembles a blob from already-signed parts. The composition is here
    /// (rather than only on the unbuilt issuing side) because the format is
    /// symmetric and the tests must mint blobs with a local test key —
    /// keeping encode and decode in one file is what keeps them from
    /// drifting apart.
    public static func compose(payloadJSON: Data, signature: Data) -> String {
        [blobPrefix, base64URLEncode(payloadJSON), base64URLEncode(signature)].joined(separator: ".")
    }

    // MARK: base64url (RFC 4648 §5, unpadded)

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        return Data(base64Encoded: standard)
    }
}

/// The Ed25519 public key baked into the app.
///
/// **There is deliberately no key here yet.** Embedding a real production
/// key requires the matching private key to exist somewhere trustworthy —
/// generated by the project owner, on the owner's machine, stored where no
/// contributor or CI run can touch it. A keypair minted during development
/// would put its private half on a development machine (or worse, in git
/// history), permanently undermining every license the scheme ever issues;
/// a keypair minted and *discarded* would embed a public key no one can
/// ever sign for. Both are worse than the honest `nil`, which
/// `LicenseEntitlementPolicy` reports as its own denial reason with
/// on-screen language, never as a silent failure.
///
/// **To go live** the owner generates the pair once, offline —
///
///     swift -e 'import CryptoKit
///       let k = Curve25519.Signing.PrivateKey()
///       print("PRIVATE (keep secret):", k.rawRepresentation.base64EncodedString())
///       print("PUBLIC  (embed below):", k.publicKey.rawRepresentation.base64EncodedString())'
///
/// — stores the private line in the checkout provider's webhook signer (and
/// a password manager), and pastes the public line into
/// `productionPublicKeyBase64`. That one-line edit is the entire go-live
/// change on the verification side.
public enum LicenseKeys {

    /// Base64 (standard, padded) of the 32-byte raw Ed25519 public key.
    /// `nil` until the owner embeds the real one — see the type doc comment
    /// for why no placeholder is used instead.
    public static let productionPublicKeyBase64: String? = nil

    /// The parsed production key, or nil when none is embedded (or the
    /// constant is not 32 valid key bytes — which would be a build-time
    /// mistake this surfaces as "no key" rather than a crash).
    public static var productionPublicKey: Curve25519.Signing.PublicKey? {
        guard
            let base64 = productionPublicKeyBase64,
            let raw = Data(base64Encoded: base64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return nil }
        return key
    }
}

// MARK: - Offline grace / revalidation policy

/// How stale a license's last successful *online* check may grow before the
/// app stops honoring it.
///
/// Signature verification is offline and proves the blob was issued; what
/// it cannot prove is that the license is still in good standing — not
/// refunded, not charged back, not revoked. That knowledge only comes from
/// the activation server (`LicenseActivationClient`), and this policy
/// governs how long its last answer stays trusted while the Mac is offline.
///
/// **The shipped default is `.never` — revalidation not required — and
/// that is a load-bearing decision, not a shrug.** This build contains no
/// concrete `LicenseActivationClient`, so nothing can ever refresh
/// `lastVerifiedAt`; a default that demanded revalidation every N days
/// would therefore lock out every legitimately licensed user exactly N
/// days after activation, with no path back. That is the "control that
/// silently breaks" failure mode this codebase exists to avoid. The grace
/// machinery is built and tested *now* so that when a real client lands,
/// enabling enforcement is a one-argument change at the composition root —
/// but enforcement must not precede the thing that makes it survivable.
public struct LicenseRevalidationPolicy: Equatable, Sendable {

    /// Seconds a successful online check remains trusted. `nil` means
    /// revalidation is never required — the cryptographic check alone
    /// suffices. nil-versus-value rather than a sentinel like `.infinity`,
    /// per the house rule that "not applicable" and "a very large number"
    /// stay distinguishable in the type system.
    public var graceWindow: TimeInterval?

    public init(graceWindow: TimeInterval?) {
        self.graceWindow = graceWindow
    }

    /// Never require an online check. The only sensible policy while no
    /// activation client exists — see the type doc comment.
    public static let never = LicenseRevalidationPolicy(graceWindow: nil)

    /// The window a real activation client would ship with: two weeks of
    /// offline trust. Long enough that a laptop taken on a month of
    /// intermittent travel isn't punished for one bad fortnight of Wi-Fi;
    /// short enough that a refunded license stops working within a
    /// business cycle. Defined and tested now, wired up never — until the
    /// client exists.
    public static let standard = LicenseRevalidationPolicy(graceWindow: 14 * 24 * 3600)
}

/// Why the app is *not* honoring a license right now, in terms precise
/// enough to put on screen. Modeled on `MCPBridgeRegistration`: every case
/// carries its own plain-language sentence, kept on the model so the UI
/// can't drift out of sync with the reason the policy actually produced.
public enum LicenseDenialReason: Equatable, Sendable {
    /// Nothing installed. The ordinary state of every unpaid copy.
    case noLicense
    /// This build embeds no production public key (`LicenseKeys`), so no
    /// blob could verify even in principle. A build-configuration truth,
    /// surfaced rather than swallowed.
    case verificationUnavailableInThisBuild
    case malformed(reason: String)
    case unsupportedFormat(prefix: String)
    case signatureInvalid
    case expired(on: Date)
    /// The license verified, but its last successful online check is
    /// outside the policy's grace window (or never happened).
    case revalidationLapsed(lastVerifiedAt: Date?, graceWindow: TimeInterval)

    /// The sentence shown next to the state. Same convention as
    /// `MCPBridgeRegistration.explanation`.
    public var explanation: String {
        switch self {
        case .noLicense:
            return "No license is installed on this Mac."
        case .verificationUnavailableInThisBuild:
            return "This build of Sentry has no license verification key embedded, so it cannot check a license at all. This is a build configuration gap, not a problem with your license."
        case .malformed:
            return "This doesn't look like a Sentry license — it may have been truncated or altered in copying. Paste the whole license exactly as it was sent to you."
        case .unsupportedFormat:
            return "This license was issued in a format this version of Sentry doesn't understand. Updating Sentry should resolve it."
        case .signatureInvalid:
            return "This license failed its authenticity check — it wasn't issued for Sentry, or it was modified after being issued."
        case .expired(let date):
            let formatted = date.formatted(date: .abbreviated, time: .omitted)
            return "This license expired on \(formatted). Everything you unlocked before then stays honest: it is expired, not broken."
        case .revalidationLapsed:
            return "Sentry hasn't been able to confirm this license with the licensing server recently, and the offline grace period has run out. Reconnect to the internet to re-confirm it."
        }
    }
}

/// The single decision every entitlement question reduces to.
public enum LicenseEntitlementDecision: Equatable, Sendable {
    case entitled(LicensePayload)
    case denied(LicenseDenialReason)

    public var isEntitled: Bool {
        if case .entitled = self { return true }
        return false
    }

    public var payload: LicensePayload? {
        if case .entitled(let payload) = self { return payload }
        return nil
    }
}

/// Combines cryptographic verification with the revalidation policy into
/// one pure decision. `LicenseProEntitlementStore` is a thin stateful shell
/// around this function; all the logic worth testing lives here, where
/// every date is a parameter.
public enum LicenseEntitlementPolicy {

    public static func decide(
        blob: String?,
        publicKey: Curve25519.Signing.PublicKey?,
        lastVerifiedAt: Date?,
        policy: LicenseRevalidationPolicy,
        now: Date
    ) -> LicenseEntitlementDecision {
        guard let blob, !blob.isEmpty else {
            return .denied(.noLicense)
        }
        // Key check *after* the blob check: a keyless build with no license
        // installed is just "no license" — the build gap only becomes the
        // user's problem when they actually hold a license it can't verify.
        guard let publicKey else {
            return .denied(.verificationUnavailableInThisBuild)
        }

        switch SignedLicense.verify(blob: blob, publicKey: publicKey, at: now) {
        case .malformed(let reason):
            return .denied(.malformed(reason: reason))
        case .unsupportedFormat(let prefix):
            return .denied(.unsupportedFormat(prefix: prefix))
        case .signatureInvalid:
            return .denied(.signatureInvalid)
        case .expired(_, let expiredAt):
            // Expiry always wins over a fresh revalidation: the server
            // confirming a license exists says nothing about its term.
            return .denied(.expired(on: expiredAt))
        case .valid(let payload):
            guard let window = policy.graceWindow else {
                return .entitled(payload)
            }
            // Inclusive at the boundary: trusted through the last instant
            // of the window, lapsed strictly after it. Never-verified under
            // a revalidation-requiring policy is lapsed from the start —
            // there is no verification to be inside a window of.
            guard let lastVerifiedAt, now <= lastVerifiedAt.addingTimeInterval(window) else {
                return .denied(.revalidationLapsed(lastVerifiedAt: lastVerifiedAt, graceWindow: window))
            }
            return .entitled(payload)
        }
    }
}
