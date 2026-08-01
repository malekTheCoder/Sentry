import CryptoKit
import Foundation
import Network
import Security

// MARK: - SyncSecurity: TLS-PSK for the remote (off-LAN) sync path

/// The security layer behind "view your Mac from another network".
///
/// **Why this exists at all.** The Bonjour/LAN transport is deliberately
/// unauthenticated plaintext (see `LocalSyncServer`'s doc comment — local
/// network, read-only telemetry, capped connections). The moment that
/// listener is reachable from outside the LAN — a port-forward, a VPN, a
/// Tailscale tailnet — "anyone on the network" stops being "your
/// household", and streaming machine names, IPs, SSIDs, and usage patterns
/// to unauthenticated strangers is not a defensible default. So the remote
/// path gets its own listener, and that listener speaks TLS with a
/// pre-shared key derived from a human-readable pairing code.
///
/// **Why TLS-PSK rather than certificates or a hand-rolled handshake.**
/// A self-signed-cert flow needs pinning UX this app has nowhere to put,
/// and a hand-rolled auth frame over plaintext TCP would authenticate but
/// not encrypt. TLS-PSK (the mechanism Apple's own peer-to-peer Network
/// framework sample uses) gives both in one primitive that both platforms
/// support natively: the connection fails during the handshake unless both
/// ends hold the same code, and everything after the handshake is
/// encrypted — so even a raw router port-forward doesn't leak telemetry in
/// the clear. Over Tailscale/WireGuard this is belt-and-suspenders, which
/// is the right posture for a listener whose reachability the app can't
/// know.
public enum SyncSecurity {

    /// Alphabet for pairing codes: Crockford-ish base32 — no 0/O, no 1/I/L,
    /// so a code read off the Mac's screen can be typed on a phone without
    /// ambiguity.
    private static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")

    /// The PSK identity hint both sides present. Constant and public on
    /// purpose: identity is not a secret (the code is), it just names the
    /// key in the handshake.
    private static let pskIdentity = "sentry-remote-sync-v1"

    /// Three groups of four, e.g. "M3QP-7TWK-9XCF" — ~62 bits from
    /// `SystemRandomNumberGenerator`, far beyond online-guessing range for
    /// a TLS handshake that fails closed.
    public static func generatePairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let groups = (0..<3).map { _ in
            String((0..<4).map { _ in codeAlphabet.randomElement(using: &generator) ?? "X" })
        }
        return groups.joined(separator: "-")
    }

    /// Normalizes user input so "m3qp 7twk 9xcf" pairs with "M3QP-7TWK-9XCF".
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// TLS options with the pre-shared key derived from `pairingCode`.
    /// Both the Mac's remote listener and the phone's direct connection
    /// build their `NWParameters` from this — one derivation, no chance of
    /// the two sides disagreeing on how the code becomes key material.
    public static func tlsOptions(pairingCode: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        // Code → key: SHA-256 over the normalized code, salted with the
        // identity string so this key can never collide with some other
        // protocol's use of the same passphrase.
        let material = Data((pskIdentity + ":" + normalize(pairingCode)).utf8)
        let keyData = Data(SHA256.hash(data: material))

        let psk = keyData.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            options.securityProtocolOptions,
            psk as __DispatchData,
            identity as __DispatchData
        )
        // PSK ciphersuites are TLS 1.2 — pin the version range and offer
        // the one suite both platforms implement, per Apple's peer-to-peer
        // TLS-PSK sample.
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv12)

        return options
    }

    /// `NWParameters` for the remote path — TLS-PSK over TCP. Shared by
    /// server listener and client connection.
    public static func remoteParameters(pairingCode: String) -> NWParameters {
        NWParameters(tls: tlsOptions(pairingCode: pairingCode), tcp: NWProtocolTCP.Options())
    }
}
