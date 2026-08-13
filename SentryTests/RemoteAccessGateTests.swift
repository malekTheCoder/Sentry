import Network
import XCTest
@testable import SentryKit

/// Coverage for `RemoteAccessGate` (`SentryKit/LocalSync/RemoteAccessGate.swift`)
/// — the pure decisions behind the `ProFeature.remoteSync` gate, exercised
/// the way `ProGate.apply`'s tests exercise the Insights cut: every axis as
/// a plain value, no `NWListener`, no entitlement store, no view hierarchy.
///
/// The split being pinned, because it is the whole point of the design:
/// a locked copy still *opens* the TLS-PSK listener (LAN pairing is the
/// free tier's only command-auth path — see `LocalSyncServer`'s trust
/// model — and ending a keep-awake from the phone must survive a lapse),
/// while what the lock actually withholds is answered per-peer: off-LAN
/// sources are refused, local ones are not.
final class RemoteAccessGateTests: XCTestCase {

    // MARK: - shouldOpenListener (entitlement-free on purpose)

    func testListenerOpensOnlyWhenEnabledWithACodeAndAPortThatFits() {
        XCTAssertTrue(RemoteAccessGate.shouldOpenListener(
            remoteSyncEnabled: true, pairingCode: "M3QP-7TWK-9XCF", port: 8643
        ))
        XCTAssertTrue(RemoteAccessGate.shouldOpenListener(
            remoteSyncEnabled: true, pairingCode: "M3QP-7TWK-9XCF", port: 65535
        ))

        XCTAssertFalse(RemoteAccessGate.shouldOpenListener(
            remoteSyncEnabled: false, pairingCode: "M3QP-7TWK-9XCF", port: 8643
        ))
        XCTAssertFalse(RemoteAccessGate.shouldOpenListener(
            remoteSyncEnabled: true, pairingCode: "", port: 8643
        ))
        XCTAssertFalse(RemoteAccessGate.shouldOpenListener(
            remoteSyncEnabled: true, pairingCode: "M3QP-7TWK-9XCF", port: 65536
        ))
        XCTAssertFalse(RemoteAccessGate.shouldOpenListener(
            remoteSyncEnabled: true, pairingCode: "M3QP-7TWK-9XCF", port: -1
        ))
    }

    /// The lapse case, pinned as a pair: a license that lapses with Remote
    /// Access enabled keeps the listener decision `true` (the paired
    /// phone's LAN command path — including *ending* a keep-awake — must
    /// survive the lapse) while the per-peer decision refuses everything
    /// that isn't on the local network. Entitlement is structurally not an
    /// input to `shouldOpenListener`; this is the behavioral proof that
    /// the two functions together implement "gate off-LAN reachability,
    /// not the listener."
    func testLapseKeepsTheListenerButRefusesOffLANPeers() {
        XCTAssertTrue(RemoteAccessGate.shouldOpenListener(
            remoteSyncEnabled: true, pairingCode: "M3QP-7TWK-9XCF", port: 8643
        ))
        XCTAssertFalse(RemoteAccessGate.permitsAuthenticatedPeer(
            isProUnlocked: false, peer: endpoint("100.101.102.103")
        ))
        XCTAssertFalse(RemoteAccessGate.permitsAuthenticatedPeer(
            isProUnlocked: false, peer: endpoint("203.0.113.7")
        ))
        XCTAssertTrue(RemoteAccessGate.permitsAuthenticatedPeer(
            isProUnlocked: false, peer: endpoint("192.168.1.20")
        ))
    }

    // MARK: - permitsAuthenticatedPeer

    /// Unlocked answers everyone — reachability from anywhere is exactly
    /// what was bought, and an unlocked copy has no business
    /// second-guessing which network a paying user connects from. Even an
    /// unclassifiable peer passes: classification exists to *withhold* the
    /// paid grant, not to firewall an entitled one.
    func testUnlockedPermitsEveryPeerIncludingUnclassifiable() {
        for peer in [
            endpoint("192.168.1.20"),      // LAN
            endpoint("100.101.102.103"),   // Tailscale/CGNAT
            endpoint("203.0.113.7"),       // public
            endpoint("example.local"),     // hostname (unclassifiable)
            nil,                           // no endpoint reported
        ] {
            XCTAssertTrue(
                RemoteAccessGate.permitsAuthenticatedPeer(isProUnlocked: true, peer: peer),
                "unlocked should permit \(String(describing: peer))"
            )
        }
    }

    func testLockedPermitsLocalIPv4Sources() {
        for address in [
            "10.0.0.5",           // RFC 1918
            "172.16.0.9",         // RFC 1918 lower bound of /12
            "172.31.255.254",     // RFC 1918 upper bound of /12
            "192.168.0.1",        // RFC 1918
            "127.0.0.1",          // loopback
            "169.254.10.20",      // link-local
        ] {
            XCTAssertTrue(
                RemoteAccessGate.permitsAuthenticatedPeer(isProUnlocked: false, peer: endpoint(address)),
                "\(address) is a local source and must stay reachable while locked"
            )
        }
    }

    func testLockedRefusesOffLANIPv4Sources() {
        for address in [
            "100.64.0.1",         // CGNAT lower bound — the Tailscale range
            "100.101.102.103",    // CGNAT middle
            "100.127.255.255",    // CGNAT upper bound
            "172.32.0.1",         // just past RFC 1918's /12
            "8.8.8.8",            // public
            "203.0.113.7",        // public (TEST-NET-3)
        ] {
            XCTAssertFalse(
                RemoteAccessGate.permitsAuthenticatedPeer(isProUnlocked: false, peer: endpoint(address)),
                "\(address) is an off-LAN source and must be refused while locked"
            )
        }
    }

    func testLockedIPv6ClassificationIncludingMappedAndULA() {
        // Local: loopback, link-local, and IPv4-mapped private (how a
        // dual-stack listener reports a LAN peer).
        for address in ["::1", "fe80::1", "::ffff:192.168.1.5"] {
            XCTAssertTrue(
                RemoteAccessGate.permitsAuthenticatedPeer(isProUnlocked: false, peer: endpoint(address)),
                "\(address) should classify local"
            )
        }
        // Not local: unique-local (the mesh-VPN range — Tailscale's own v6
        // addresses are fd7a:…), global unicast, and mapped-public.
        for address in ["fd7a:115c:a1e0::1", "2001:db8::1", "::ffff:8.8.8.8"] {
            XCTAssertFalse(
                RemoteAccessGate.permitsAuthenticatedPeer(isProUnlocked: false, peer: endpoint(address)),
                "\(address) should classify off-LAN"
            )
        }
    }

    /// Fail closed: a peer we can't place (a hostname endpoint, or no
    /// endpoint at all) gets no benefit of the doubt while locked —
    /// refusing a local peer is recoverable, granting the paid path to an
    /// unknown one is not.
    func testLockedRefusesUnclassifiablePeers() {
        XCTAssertFalse(RemoteAccessGate.permitsAuthenticatedPeer(
            isProUnlocked: false, peer: endpoint("example.local")
        ))
        XCTAssertFalse(RemoteAccessGate.permitsAuthenticatedPeer(
            isProUnlocked: false, peer: nil
        ))
    }

    /// The live-flip axis: the same peer flips answer with the entitlement
    /// alone. In the app this is what makes a license paste or lapse take
    /// effect on the very next inbound connection —
    /// `AppDelegate.applySettings` pushes the fresh answer into
    /// `LocalSyncServer.setRemoteAccessUnlocked` on every settings
    /// emission, and the accept gate re-asks per peer.
    func testEntitlementFlipFlipsTheAnswerForTheSamePeer() {
        let tailscalePeer = endpoint("100.101.102.103")
        XCTAssertFalse(RemoteAccessGate.permitsAuthenticatedPeer(isProUnlocked: false, peer: tailscalePeer))
        XCTAssertTrue(RemoteAccessGate.permitsAuthenticatedPeer(isProUnlocked: true, peer: tailscalePeer))
    }

    // MARK: - visibleHostCandidates

    func testLockedCandidatesDropTunnelAddressesAndKeepLANOrder() {
        let candidates = [
            RemotePairing.HostCandidate(address: "100.101.102.103", interfaceName: "utun4", kind: .tailscale),
            RemotePairing.HostCandidate(address: "192.168.1.20", interfaceName: "en0", kind: .lan),
            RemotePairing.HostCandidate(address: "10.0.1.4", interfaceName: "en1", kind: .lan),
        ]

        let locked = RemoteAccessGate.visibleHostCandidates(candidates, isProUnlocked: false)
        XCTAssertEqual(locked.map(\.address), ["192.168.1.20", "10.0.1.4"])
        XCTAssertFalse(
            locked.contains { $0.kind == .tailscale },
            "a locked pairing surface must never render a tunnel address — it is the withheld off-LAN value"
        )

        // Unlocked passes the ranked list through untouched.
        XCTAssertEqual(
            RemoteAccessGate.visibleHostCandidates(candidates, isProUnlocked: true).map(\.address),
            candidates.map(\.address)
        )
    }

    /// A Mac whose only address is a tunnel address has nothing a locked QR
    /// may show — the empty list is the honest answer, and both pairing
    /// surfaces already render an explicit "no usable address" state for it.
    func testLockedCandidatesCanBeHonestlyEmpty() {
        let tunnelOnly = [
            RemotePairing.HostCandidate(address: "100.101.102.103", interfaceName: "utun4", kind: .tailscale)
        ]
        XCTAssertTrue(RemoteAccessGate.visibleHostCandidates(tunnelOnly, isProUnlocked: false).isEmpty)
    }

    // MARK: - Helpers

    /// Builds the same shape `NWConnection.endpoint` reports for an
    /// accepted inbound connection: `.hostPort`. A literal address parses
    /// to `.ipv4`/`.ipv6`; anything else becomes `.name`, which is the
    /// unclassifiable case.
    private func endpoint(_ host: String) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: 8643)
    }
}
