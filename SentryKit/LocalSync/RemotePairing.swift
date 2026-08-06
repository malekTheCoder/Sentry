import Darwin
import Foundation

// MARK: - RemotePairing: the QR/deep-link handshake for remote access

/// The one shared definition of the `sentry://pair` link that carries a
/// Mac's remote-access endpoint to the phone — built by the Mac's Sync
/// settings pane (rendered as a QR code), parsed by the iPhone app's
/// `onOpenURL` when the Camera app scans it.
///
/// **Why a URL scheme rather than an in-app scanner.** Scanning with the
/// built-in Camera app and tapping the "Open in Sentry" banner needs no
/// camera-permission prompt, no AVFoundation session, and no scanner UI in
/// this app at all — the OS does the scanning and the app only has to parse
/// a URL it registered for. The cost is that the link format is now a
/// public contract between the two apps, which is exactly why it lives here
/// in SentryKit next to `SyncSecurity` instead of being string-built in
/// one app and string-picked-apart in the other.
///
/// **What the link deliberately contains.** Host, port, and the pairing
/// code — the same three fields the phone's manual entry form asks for, no
/// more. The code is a secret, but a QR rendered on the Mac's own screen is
/// already inside the trust boundary the code protects (someone who can
/// photograph your Mac's settings pane can also just read the code shown
/// beside it).
public enum RemotePairing {

    /// URL scheme + host, e.g. `sentry://pair?host=…&port=…&code=…`.
    /// The iPhone target's Info.plist registers `sentry` under
    /// `CFBundleURLTypes`; changing either constant is a breaking change to
    /// already-printed/screenshotted QR codes.
    public static let scheme = "sentry"
    public static let action = "pair"

    /// The three fields the phone needs — mirrors `LocalSyncClient
    /// .configureDirectEndpoint(host:port:pairingCode:)` exactly.
    public struct Endpoint: Equatable, Sendable {
        public let host: String
        public let port: UInt16
        public let code: String

        public init(host: String, port: UInt16, code: String) {
            self.host = host
            self.port = port
            self.code = code
        }
    }

    /// Builds the link the QR code encodes. Returns `nil` only when the
    /// inputs couldn't form a valid URL (empty host/code) — the settings
    /// pane guards against showing a QR for a half-configured state anyway.
    public static func url(for endpoint: Endpoint) -> URL? {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = SyncSecurity.normalize(endpoint.code)
        guard !host.isEmpty, !code.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(endpoint.port)),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url
    }

    /// Parses a scanned/opened link back into an endpoint. `nil` for
    /// anything that isn't a well-formed `sentry://pair` URL with a
    /// non-empty host and code — a missing/invalid port falls back to the
    /// default rather than failing, matching the manual entry form's
    /// behavior when the port field is left alone.
    public static func endpoint(from url: URL, defaultPort: UInt16 = 8643) -> Endpoint? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == action,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var host = ""
        var code = ""
        var port = defaultPort
        for item in components.queryItems ?? [] {
            switch item.name {
            case "host": host = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case "code": code = SyncSecurity.normalize(item.value ?? "")
            case "port": port = UInt16(item.value ?? "") ?? defaultPort
            default: break
            }
        }
        guard !host.isEmpty, !code.isEmpty, port > 0 else { return nil }
        return Endpoint(host: host, port: port, code: code)
    }

    // MARK: - Host candidates (the Mac-side "what address goes in the QR" question)

    /// One address this machine is reachable at, with enough classification
    /// for the settings pane to rank and label it.
    public struct HostCandidate: Equatable, Identifiable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// In 100.64.0.0/10 — almost certainly a Tailscale (or other
            /// CGNAT-range VPN) address, reachable from any network the
            /// tailnet spans. The best QR payload when present.
            case tailscale
            /// RFC-1918 private space — reachable on this LAN only (where
            /// Bonjour already works without any of this), but still the
            /// honest fallback when no tunnel address exists.
            case lan
        }

        public let address: String
        public let interfaceName: String
        public let kind: Kind

        public var id: String { address }
    }

    /// Enumerates this machine's IPv4 addresses via `getifaddrs`, ranked
    /// Tailscale-first. Loopback, link-local (169.254/16), and non-IPv4
    /// families are skipped; anything public is skipped too — a Mac's
    /// directly-public IPv4 is rare, usually ephemeral, and a router
    /// port-forward user knows their external address better than this
    /// enumeration ever could.
    public static func hostCandidates() -> [HostCandidate] {
        var addresses: [HostCandidate] = []
        var ifaddrsPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPointer) == 0, let first = ifaddrsPointer else { return [] }
        defer { freeifaddrs(ifaddrsPointer) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addrPointer = ifa.ifa_addr,
                  addrPointer.pointee.sa_family == sa_family_t(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0,
                  (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0
            else { continue }

            var sockaddrIn = sockaddr_in()
            memcpy(&sockaddrIn, addrPointer, min(Int(addrPointer.pointee.sa_len), MemoryLayout<sockaddr_in>.size))
            let raw = UInt32(bigEndian: sockaddrIn.sin_addr.s_addr)

            let octet1 = (raw >> 24) & 0xFF
            let octet2 = (raw >> 16) & 0xFF

            // Link-local (169.254/16) — never routable off-machine-pair.
            if octet1 == 169, octet2 == 254 { continue }

            let kind: HostCandidate.Kind
            if octet1 == 100, (64...127).contains(octet2) {
                kind = .tailscale
            } else if octet1 == 10
                || (octet1 == 172 && (16...31).contains(octet2))
                || (octet1 == 192 && octet2 == 168) {
                kind = .lan
            } else {
                continue
            }

            var addressChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = sockaddrIn.sin_addr
            guard inet_ntop(AF_INET, &sinAddr, &addressChars, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let address = String(cString: addressChars)
            let name = String(cString: pointer.pointee.ifa_name)
            addresses.append(HostCandidate(address: address, interfaceName: name, kind: kind))
        }

        // Tailscale first, then LAN; stable within each group. Duplicate
        // addresses (aliased interfaces) collapse to the first sighting.
        var seen = Set<String>()
        return addresses
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .tailscale }
                return false
            }
            .filter { seen.insert($0.address).inserted }
    }
}
