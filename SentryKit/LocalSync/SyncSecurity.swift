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

    /// TCP keepalive idle time for the remote (TLS-PSK) path, in seconds —
    /// how long the connection sits silent before the OS starts sending
    /// keepalive probes. Without this, `NWConnection` can sit in `.ready`
    /// long after the underlying path is actually dead (Mac asleep, phone
    /// backgrounded on cellular, a silent NAT/VPN drop that never sends a
    /// TCP RST) — `LocalSyncClient.isReady`, and therefore
    /// `AppDataSource.isLocalSyncConnected`, keeps reporting "live" with
    /// nothing on the other end (connection-honesty review gap #1).
    ///
    /// **Why 15s, not shorter or longer.** A remote tunnel (Tailscale/VPN,
    /// or a router port-forward reached over cellular) is exactly the path
    /// this listener exists for, and it's also the path where a dead peer
    /// is least likely to announce itself with a clean RST — the failure
    /// mode this exists to catch. Shorter (e.g. 2-5s) would fire probes
    /// often enough to matter for cellular data/battery on a connection
    /// that, once paired, is meant to sit open for the lifetime of the
    /// session; longer (e.g. 60s+) leaves `isLocalSyncConnected` lying for
    /// up to a minute, which is the whole bug this fixes. 15s is the same
    /// order of magnitude Apple's own `URLSession` background-transfer
    /// guidance uses for "detect a stalled peer without being chatty," and
    /// is short enough that a user who force-quits the Mac app or puts the
    /// Mac to sleep sees the phone's connection state catch up within one
    /// UI-refresh's worth of waiting, not a coffee break.
    static let keepaliveIdleSeconds: TimeInterval = 15

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
    /// server listener and client connection, so both ends independently
    /// notice a dead peer via `keepaliveIdleSeconds` above rather than only
    /// one side detecting the drop.
    public static func remoteParameters(pairingCode: String) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = Int(keepaliveIdleSeconds)
        return NWParameters(tls: tlsOptions(pairingCode: pairingCode), tcp: tcpOptions)
    }
}
