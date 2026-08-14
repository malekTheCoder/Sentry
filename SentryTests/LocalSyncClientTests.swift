import Network
import XCTest
@testable import Sentry
import SentryKit

/// Coverage for `LocalSyncClient`'s pure, `Network.framework`-I/O-free
/// helpers (`SentryKit/LocalSync/LocalSyncClient.swift`) — the two pieces of
/// logic from the connection-honesty review that can actually be exercised
/// without a live `NWBrowser`/`NWConnection`:
///
/// 1. `preferredEndpoint(among:preferring:)` — gap #5, "prefer reconnecting
///    to the same Mac instead of silently switching on a drop."
/// 2. `classifyDirectConnectFailure(_:)` — gap #2, "wrong pairing code vs.
///    unreachable Mac."
///
/// Everything else touched by this pass (TCP keepalive, `NSWorkspace`
/// sleep/wake observation) is Network-framework/OS-lifecycle behavior with
/// no meaningful in-process unit test — see this file's bottom comment.
final class LocalSyncClientTests: XCTestCase {

    // MARK: - Fixtures

    /// `NWEndpoint.service` is a publicly constructible case (unlike
    /// `NWBrowser.Result`, which has no public initializer at all) — this is
    /// what makes fabricating browse-result-shaped input for a pure
    /// function possible without a live browser.
    private func service(named name: String, domain: String = "local.") -> NWEndpoint {
        .service(name: name, type: LocalSyncClient.serviceType, domain: domain, interface: nil)
    }

    private func hostPort(_ host: String = "10.0.0.5", _ port: UInt16 = 8643) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }

    // MARK: - serviceIdentity(for:)

    func testServiceIdentityExtractsNameFromServiceEndpoint() {
        XCTAssertEqual(LocalSyncClient.serviceIdentity(for: service(named: "Demo User's MacBook Pro")), "Demo User's MacBook Pro")
    }

    func testServiceIdentityIsNilForNonServiceEndpoint() {
        XCTAssertNil(LocalSyncClient.serviceIdentity(for: hostPort()))
    }

    // MARK: - preferredEndpoint(among:preferring:)

    func testPreferredEndpointReturnsFirstWhenNoPreferenceYet() {
        let a = service(named: "Mac A")
        let b = service(named: "Mac B")
        let result = LocalSyncClient.preferredEndpoint(among: [a, b], preferring: nil)
        XCTAssertEqual(result, a)
    }

    func testPreferredEndpointReturnsNilForEmptyResults() {
        XCTAssertNil(LocalSyncClient.preferredEndpoint(among: [], preferring: "Mac A"))
    }

    /// The core two-Mac-household regression this fix targets: the
    /// previously-connected Mac ("Mac B") is not first in this browse, but
    /// it must still win over "Mac A" because the client remembers it.
    func testPreferredEndpointPrefersRememberedServiceEvenWhenNotFirst() {
        let a = service(named: "Mac A")
        let b = service(named: "Mac B")
        let result = LocalSyncClient.preferredEndpoint(among: [a, b], preferring: "Mac B")
        XCTAssertEqual(result, b)
    }

    /// The remembered Mac dropped off Bonjour entirely (powered off, left
    /// the network) — nothing to prefer, so this falls back to whichever
    /// result is first rather than returning nil and refusing to reconnect
    /// to anything.
    func testPreferredEndpointFallsBackToFirstWhenRememberedServiceIsGone() {
        let a = service(named: "Mac A")
        let c = service(named: "Mac C")
        let result = LocalSyncClient.preferredEndpoint(among: [a, c], preferring: "Mac B")
        XCTAssertEqual(result, a)
    }

    func testPreferredEndpointMatchesOnNameAcrossDifferentDomains() {
        // Same advertised name, different domain string — still "the same
        // Mac" for this purpose; `serviceIdentity` compares by name only.
        let sameNameDifferentDomain = service(named: "Mac B", domain: "local2.")
        let a = service(named: "Mac A")
        let result = LocalSyncClient.preferredEndpoint(among: [a, sameNameDifferentDomain], preferring: "Mac B")
        XCTAssertEqual(result, sameNameDifferentDomain)
    }

    // MARK: - discoveredMacs(from:) — the multi-Mac picker's list mapping

    func testDiscoveredMacsMapsServiceEndpointsToEntries() {
        let macs = LocalSyncClient.discoveredMacs(from: [service(named: "Mac A"), service(named: "Mac B")])
        XCTAssertEqual(macs.map(\.id), ["Mac A", "Mac B"])
    }

    func testDiscoveredMacsFiltersOutNonServiceEndpoints() {
        let macs = LocalSyncClient.discoveredMacs(from: [service(named: "Mac A"), hostPort()])
        XCTAssertEqual(macs.map(\.id), ["Mac A"])
    }

    /// The same Mac can legitimately appear as more than one browse result
    /// (e.g. advertised over two interfaces) — the picker should still show
    /// it exactly once, not once per interface.
    func testDiscoveredMacsDeduplicatesByServiceName() {
        let macs = LocalSyncClient.discoveredMacs(
            from: [service(named: "Mac A"), service(named: "Mac A", domain: "local2.")]
        )
        XCTAssertEqual(macs.map(\.id), ["Mac A"])
    }

    /// `NWBrowser.browseResults` is a `Set` — this function's stable,
    /// alphabetical sort is what keeps the picker's row order from
    /// reshuffling on every unrelated browse-results update.
    func testDiscoveredMacsSortsAlphabeticallyRegardlessOfInputOrder() {
        let macs = LocalSyncClient.discoveredMacs(from: [service(named: "Zeta"), service(named: "Alpha")])
        XCTAssertEqual(macs.map(\.id), ["Alpha", "Zeta"])
    }

    func testDiscoveredMacsIsEmptyForNoEndpoints() {
        XCTAssertTrue(LocalSyncClient.discoveredMacs(from: []).isEmpty)
    }

    // MARK: - hasMultipleMacs(_:) — the picker's show/hide gate

    func testHasMultipleMacsIsFalseForZeroMacs() {
        XCTAssertFalse(LocalSyncClient.hasMultipleMacs([]))
    }

    func testHasMultipleMacsIsFalseForExactlyOneMac() {
        XCTAssertFalse(LocalSyncClient.hasMultipleMacs([DiscoveredMac(id: "Mac A", endpoint: service(named: "Mac A"))]))
    }

    func testHasMultipleMacsIsTrueForTwoOrMoreMacs() {
        let macs = [
            DiscoveredMac(id: "Mac A", endpoint: service(named: "Mac A")),
            DiscoveredMac(id: "Mac B", endpoint: service(named: "Mac B")),
        ]
        XCTAssertTrue(LocalSyncClient.hasMultipleMacs(macs))
    }

    // MARK: - isSwitchingMac(from:to:) — the picker row's tap-to-switch logic

    func testIsSwitchingMacIsFalseWhenTappingTheAlreadyConnectedMac() {
        let mac = DiscoveredMac(id: "Mac A", endpoint: service(named: "Mac A"))
        XCTAssertFalse(LocalSyncClient.isSwitchingMac(from: "Mac A", to: mac))
    }

    func testIsSwitchingMacIsTrueWhenTappingADifferentMac() {
        let mac = DiscoveredMac(id: "Mac B", endpoint: service(named: "Mac B"))
        XCTAssertTrue(LocalSyncClient.isSwitchingMac(from: "Mac A", to: mac))
    }

    func testIsSwitchingMacIsTrueWhenNothingIsConnectedYet() {
        let mac = DiscoveredMac(id: "Mac A", endpoint: service(named: "Mac A"))
        XCTAssertTrue(LocalSyncClient.isSwitchingMac(from: nil, to: mac))
    }

    // MARK: - classifyDirectConnectFailure(_:)

    func testClassifyDirectConnectFailureTreatsNoErrorAsUnreachable() {
        XCTAssertEqual(LocalSyncClient.classifyDirectConnectFailure(nil), .unreachable)
    }

    func testClassifyDirectConnectFailureTreatsTLSErrorAsWrongPairingCode() {
        let tlsError = NWError.tls(errSSLPeerHandshakeFail)
        XCTAssertEqual(LocalSyncClient.classifyDirectConnectFailure(tlsError), .wrongPairingCode)
    }

    func testClassifyDirectConnectFailureTreatsPosixConnectionRefusedAsUnreachable() {
        let posixError = NWError.posix(.ECONNREFUSED)
        XCTAssertEqual(LocalSyncClient.classifyDirectConnectFailure(posixError), .unreachable)
    }

    func testClassifyDirectConnectFailureTreatsPosixTimeoutAsUnreachable() {
        let posixError = NWError.posix(.ETIMEDOUT)
        XCTAssertEqual(LocalSyncClient.classifyDirectConnectFailure(posixError), .unreachable)
    }

    func testClassifyDirectConnectFailureTreatsDNSErrorAsUnreachable() {
        let dnsError = NWError.dns(0)
        XCTAssertEqual(LocalSyncClient.classifyDirectConnectFailure(dnsError), .unreachable)
    }
}

// MARK: - What isn't covered here, and why

/// TCP keepalive (`SyncSecurity.keepaliveIdleSeconds`,
/// `LocalSyncClient.lanParameters()`, `SyncSecurity.remoteParameters(
/// pairingCode:)`) configures `NWProtocolTCP.Options` that only take effect
/// inside the kernel's TCP stack on a real socket — there is no in-process
/// way to observe "did this `NWConnection` actually send a keepalive probe
/// after N idle seconds" without a live two-sided connection and a multi-
/// second wait, which would make this an integration test, not a unit test,
/// and a flaky/slow one at that. Verified instead by reading back
/// `enableKeepalive`/`keepaliveIdle` off the constructed `NWProtocolTCP
/// .Options` during manual review of this change, and by exercising a real
/// connection in the iOS Simulator + Mac app during this task's manual
/// verification pass.
///
/// `LocalSyncServer`'s `NSWorkspace.willSleepNotification`/
/// `didWakeNotification` handling is OS-lifecycle behavior — actually
/// putting a test machine to sleep from an automated test is impractical
/// and would hang CI. `handleSystemWillSleep()`'s connection-closing logic
/// was verified by manual inspection (it reuses the exact same `queue
/// .async { ... state.connection.cancel() ... connections.removeAll() }`
/// shape `stop()` already uses, which *is* covered indirectly by every test
/// that exercises `LocalSyncServer.stop()`).
private enum LocalSyncClientTestsCoverageNotes {}
