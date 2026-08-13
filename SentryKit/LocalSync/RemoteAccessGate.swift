import Foundation
import Network

// MARK: - RemoteAccessGate: the pure decisions behind the Remote Access Pro gate

/// The decision layer for `ProFeature.remoteSync` — what a locked copy of
/// Sentry may and may not do with the TLS-PSK Remote Access listener. Pure
/// functions of plain values, in the `ProGate.apply` /
/// `WalkthroughGate.completedFlag` convention: the composition root and
/// `LocalSyncServer` ask; nothing here holds state, reads settings, or
/// touches an entitlement store.
///
/// **What is gated, precisely — and what is deliberately not.** Sentry Pro
/// sells *reachability from outside the local network*. It does not sell
/// the pairing handshake itself, because the trust model documented on
/// `LocalSyncServer` gives that handshake a second, free job: commands
/// (the phone's sleep card, Siri intents) are only accepted over the
/// authenticated TLS-PSK connection *even on the LAN* — the plaintext
/// Bonjour listener is read-only by policy. Gating the whole listener
/// would therefore not just gate the paid feature; it would sever a free
/// user's — or a lapsed license's — only path to *ending* a keep-awake
/// from the phone, and anything that releases or stops must never sit
/// behind the paywall. So the split is:
///
///   - **Free, always:** Bonjour discovery + snapshot broadcast (untouched
///     by this file entirely), and opening the TLS-PSK listener for
///     pairing and command auth on the local network.
///   - **Pro:** that same listener answering a peer that is *not* on the
///     local network — the "view this Mac from anywhere" grant.
///
/// **Why entitlement is not an input to `shouldOpenListener`.** See above:
/// the listener must open for a locked copy too, or LAN command auth dies
/// with a lapse. Entitlement enters exactly once, in
/// `permitsAuthenticatedPeer`, where the off-LAN grant is actually
/// exercised.
///
/// **This is honest-effort gating, not DRM** — the same posture
/// `LicenseProEntitlementStore`'s header takes for the license file
/// itself. Peer-address classification can be fooled by someone who
/// NATs their tunnel behind their own router; it cannot be fooled by
/// accident, and it cleanly refuses the two arrangements the feature is
/// actually sold for (Tailscale-style tunnels and router port-forwards).
/// Classification decisions worth naming:
///
///   - **100.64.0.0/10 (CGNAT) is not local.** It is the address space
///     Tailscale and similar mesh VPNs hand out — the primary off-LAN
///     transport, and the same range `RemotePairing.HostCandidate.Kind`
///     already classifies as `.tailscale`.
///   - **IPv6 unique-local (fc00::/7) is not local.** Mesh VPNs hand out
///     `fd…` addresses too (Tailscale's own v6 range is ULA); genuinely
///     same-network traffic reaches this Mac over RFC 1918 IPv4 — the only
///     family `RemotePairing.hostCandidates()` ever puts in the QR — or
///     over link-local v6, both of which classify local.
///   - **Unclassifiable peers fail closed when locked** (a hostname
///     endpoint, an address family this file doesn't know): refusing a
///     peer we can't place is recoverable; granting the paid path to one
///     we can't place is not.
public enum RemoteAccessGate {

    // MARK: - Opening the listener (entitlement-free on purpose)

    /// Whether the TLS-PSK listener should be open at all — the same
    /// enabled + code-nonempty + port-fits conjunction
    /// `AppDelegate.applySettings` wires to
    /// `LocalSyncServer.enableRemote`/`disableRemote`, extracted so the
    /// axes are pinnable in a unit test.
    ///
    /// Deliberately **not** a function of entitlement — a lapsed license
    /// with Remote Access already enabled keeps this listener open so the
    /// paired phone can still pair and issue commands on the LAN
    /// (including ending a keep-awake, the escape hatch); what the lapse
    /// actually revokes is decided per-peer in
    /// `permitsAuthenticatedPeer`. Never silent: `SyncPane`'s locked row
    /// states the refusal in words on the same screen as the toggle.
    public static func shouldOpenListener(
        remoteSyncEnabled: Bool,
        pairingCode: String,
        port: Int
    ) -> Bool {
        remoteSyncEnabled
            && !pairingCode.isEmpty
            && UInt16(exactly: port) != nil
    }

    // MARK: - Accepting a peer (where the Pro grant is exercised)

    /// Whether an inbound connection on the TLS-PSK listener may proceed.
    /// Unlocked copies answer any peer (reachability is exactly what was
    /// bought); locked copies answer only peers whose source address places
    /// them on this Mac's own network. `nil` — an endpoint
    /// `Network.framework` didn't report — fails closed when locked.
    public static func permitsAuthenticatedPeer(
        isProUnlocked: Bool,
        peer: NWEndpoint?
    ) -> Bool {
        if isProUnlocked { return true }
        guard case .hostPort(let host, _)? = peer else { return false }
        return isLocalNetworkHost(host)
    }

    /// Whether `host` is a local-network source address. `.name` fails
    /// closed: an *accepted inbound* connection reports a literal address,
    /// so a hostname here means we genuinely don't know where the peer is.
    public static func isLocalNetworkHost(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return isLocalIPv4(address)
        case .ipv6(let address):
            return isLocalIPv6(address)
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    /// RFC 1918 (10/8, 172.16/12, 192.168/16), loopback (127/8), and
    /// link-local (169.254/16) are local. CGNAT (100.64/10 — the
    /// Tailscale range) and all public space are not; see the type's doc
    /// comment for why CGNAT is the load-bearing exclusion.
    public static func isLocalIPv4(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return false }
        let (o1, o2) = (bytes[0], bytes[1])
        if o1 == 127 { return true }
        if o1 == 10 { return true }
        if o1 == 172, (16...31).contains(o2) { return true }
        if o1 == 192, o2 == 168 { return true }
        if o1 == 169, o2 == 254 { return true }
        return false
    }

    /// Loopback and link-local are local; an IPv4-mapped address is
    /// classified as the IPv4 it wraps (a dual-stack listener reports LAN
    /// peers this way). Everything else — global unicast *and*
    /// unique-local (fc00::/7, the mesh-VPN range) — is not local; see the
    /// type's doc comment for the ULA reasoning.
    public static func isLocalIPv6(_ address: IPv6Address) -> Bool {
        if address.isLoopback { return true }
        if address.isLinkLocal { return true }
        if let mapped = address.asIPv4 { return isLocalIPv4(mapped) }
        return false
    }

    // MARK: - What a locked pairing surface may show

    /// The host candidates a pairing QR / picker may render. Unlocked
    /// copies see every candidate, Tailscale-first, as
    /// `RemotePairing.hostCandidates()` ranked them. Locked copies see
    /// only `.lan` candidates: a tunnel address *is* the off-LAN value the
    /// gate withholds, and a QR encoding one would both leak it and walk a
    /// free user into a connection this Mac then refuses — the
    /// confident-control-describing-a-false-reality shape `SyncPane`'s
    /// house rule P5 forbids.
    public static func visibleHostCandidates(
        _ candidates: [RemotePairing.HostCandidate],
        isProUnlocked: Bool
    ) -> [RemotePairing.HostCandidate] {
        guard !isProUnlocked else { return candidates }
        return candidates.filter { $0.kind == .lan }
    }
}
