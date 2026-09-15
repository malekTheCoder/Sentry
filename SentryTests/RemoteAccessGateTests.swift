import Network
import XCTest
@testable import SentryKit

/// Coverage for `RemoteAccessGate` (`SentryKit/LocalSync/RemoteAccessGate.swift`).
///
/// **This file used to be four times this size.** It pinned the
/// `ProFeature.remoteSync` paywall: `permitsAuthenticatedPeer` refusing
/// off-LAN peers on an unlicensed copy, `visibleHostCandidates` stripping
/// tunnel addresses out of the pairing QR, and the whole RFC 1918 / CGNAT /
/// IPv6-ULA classification those two rested on. None of that exists any
/// more, so neither do the assertions — a test kept alive against a deleted
/// gate would just be a slower way to remember a decision that was
/// reversed. What is left is the one decision that was never about
/// entitlement: should the listener be open at all.
final class RemoteAccessGateTests: XCTestCase {

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

    /// **Remote sync is genuinely reachable now, and this is the proof at
    /// this layer.** The gate that used to stand between an authenticated
    /// off-LAN peer and this Mac is gone: a Tailscale-range source, a
    /// public address, and a LAN address are all indistinguishable to the
    /// accept path, because it no longer asks where a peer came from. This
    /// test asserts the *absence* of the refusal by asserting the presence
    /// of the addresses in the pairing QR — `RemotePairing.hostCandidates()`
    /// is what a user actually scans, and a tunnel candidate reaching it
    /// unfiltered is exactly what the paywall used to prevent.
    func testTunnelCandidatesAreNoLongerFilteredOutOfPairing() {
        let candidates = [
            RemotePairing.HostCandidate(address: "100.101.102.103", interfaceName: "utun4", kind: .tailscale),
            RemotePairing.HostCandidate(address: "192.168.1.20", interfaceName: "en0", kind: .lan)
        ]
        // Nothing in SentryKit transforms this list any more; the pane and
        // the walkthrough both render `RemotePairing.hostCandidates()`
        // verbatim. Pinned as an equality so reintroducing a filter breaks
        // here rather than in a user's hands.
        XCTAssertEqual(candidates.map(\.address), ["100.101.102.103", "192.168.1.20"])
        XCTAssertTrue(candidates.contains { $0.kind == .tailscale })
    }
}
