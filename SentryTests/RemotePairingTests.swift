import XCTest
import SentryKit

/// Coverage for `RemotePairing`'s URL contract
/// (`SentryKit/LocalSync/RemotePairing.swift`) — the `sentry://pair` link
/// the Mac renders as a QR and the phone parses in `onOpenURL`. A
/// pre-existing gap noted while gating `ProFeature.remoteSync`: this is a
/// public contract between two apps (that file's own doc comment), and
/// until now nothing pinned that `url(for:)` and `endpoint(from:)` agree.
final class RemotePairingTests: XCTestCase {

    func testEndpointRoundTripsThroughTheURL() throws {
        let endpoint = RemotePairing.Endpoint(host: "192.168.1.20", port: 8643, code: "M3QP-7TWK-9XCF")
        let url = try XCTUnwrap(RemotePairing.url(for: endpoint))
        let parsed = try XCTUnwrap(RemotePairing.endpoint(from: url))

        XCTAssertEqual(parsed.host, "192.168.1.20")
        XCTAssertEqual(parsed.port, 8643)
        // The code normalizes on both write and read (`SyncSecurity
        // .normalize`), so the round-trip lands on the canonical form.
        XCTAssertEqual(parsed.code, "M3QP7TWK9XCF")
    }

    func testURLRefusesHalfConfiguredEndpoints() {
        XCTAssertNil(RemotePairing.url(for: .init(host: "", port: 8643, code: "M3QP-7TWK-9XCF")))
        XCTAssertNil(RemotePairing.url(for: .init(host: "192.168.1.20", port: 8643, code: "")))
        XCTAssertNil(RemotePairing.url(for: .init(host: "   ", port: 8643, code: "M3QP-7TWK-9XCF")))
    }

    func testParsingToleratesAMissingPortByFallingBackToTheDefault() throws {
        let url = try XCTUnwrap(URL(string: "sentry://pair?host=192.168.1.20&code=M3QP7TWK9XCF"))
        let parsed = try XCTUnwrap(RemotePairing.endpoint(from: url))
        XCTAssertEqual(parsed.port, 8643)
    }

    func testParsingRefusesForeignAndMalformedURLs() throws {
        for candidate in [
            "https://pair?host=a&code=b",       // wrong scheme
            "sentry://elsewhere?host=a&code=b", // wrong action
            "sentry://pair?host=&code=b",       // empty host
            "sentry://pair?host=a&code=",       // empty code
        ] {
            let url = try XCTUnwrap(URL(string: candidate))
            XCTAssertNil(RemotePairing.endpoint(from: url), "should refuse \(candidate)")
        }
    }
}
