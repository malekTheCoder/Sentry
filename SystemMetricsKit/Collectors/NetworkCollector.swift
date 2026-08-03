import CoreWLAN
import Darwin
import Foundation
import SentryKit
import SystemConfiguration

/// Reads per-interface byte counters via `getifaddrs`, converts them to
/// throughput with `DeltaTracker`, and (optionally) enriches the result with
/// Wi-Fi radio details from CoreWLAN.
public final class NetworkCollector: Collector {
    /// Per-interface rate trackers. Kept separate per name so a counter reset
    /// or wrap on one interface never pollutes another's delta math.
    private var deltaTrackers: [String: (rx: DeltaTracker, tx: DeltaTracker)] = [:]

    /// First-seen counter value per interface, used as the baseline for
    /// "session total" (bytes since this collector started observing it).
    private var sessionBaselines: [String: (rx: UInt64, tx: UInt64)] = [:]

    /// Reading the Wi-Fi SSID triggers a macOS Location Services permission
    /// prompt on Sonoma+. This must stay opt-in and default off so the app
    /// never prompts for location at launch — see plan §5.7.
    private let includeSSID: Bool

    public init(includeSSID: Bool = false) {
        self.includeSSID = includeSSID
    }

    public func collect() -> NetworkStats? {
        let counters = Self.readInterfaceCounters()
        guard let active = Self.pickActiveInterface(from: counters) else { return nil }

        let now = Date()
        // ifi_ibytes/ifi_obytes are genuinely 32-bit BSD if_data counters, so
        // wrap-through-UInt32.max math is safe and correct here.
        let tracker = deltaTrackers[active.name] ?? (DeltaTracker(width: .bits32), DeltaTracker(width: .bits32))
        deltaTrackers[active.name] = tracker
        let rxRate = tracker.rx.rate(for: active.rx, at: now)
        let txRate = tracker.tx.rate(for: active.tx, at: now)

        let baseline = sessionBaselines[active.name]
        let sessionRx: UInt64
        let sessionTx: UInt64
        if let baseline, active.rx >= baseline.rx, active.tx >= baseline.tx {
            sessionRx = active.rx - baseline.rx
            sessionTx = active.tx - baseline.tx
        } else {
            // First sighting, or the interface's counters reset (e.g. link
            // flap / re-association) — start a fresh baseline at zero.
            sessionBaselines[active.name] = (active.rx, active.tx)
            sessionRx = 0
            sessionTx = 0
        }

        let wifiInterfaces = CWWiFiClient.shared().interfaces() ?? []
        let matchingWiFi = wifiInterfaces.first { $0.interfaceName == active.name }

        var ssid: String?
        if includeSSID {
            // Only touch `.ssid()` when explicitly enabled — this is the call
            // that triggers the Location Services prompt on macOS 14+.
            ssid = matchingWiFi?.ssid()
        }

        return NetworkStats(
            rxBytesPerSec: rxRate ?? 0,
            txBytesPerSec: txRate ?? 0,
            rxSessionTotalBytes: sessionRx,
            txSessionTotalBytes: sessionTx,
            activeInterface: active.name,
            isWiFi: matchingWiFi != nil,
            localIPAddress: active.localIPAddress,
            wifiSSID: ssid,
            wifiRSSIdBm: matchingWiFi?.rssiValue(),
            wifiNoisedBm: matchingWiFi?.noiseMeasurement(),
            wifiTxRateMbps: matchingWiFi?.transmitRate()
        )
    }

    // MARK: - Interface enumeration

    private struct InterfaceCounters {
        var name: String
        var rx: UInt64
        var tx: UInt64
        var isUp: Bool
        var localIPAddress: String?
    }

    /// Walks `getifaddrs` once, combining the `AF_LINK` byte counters and the
    /// first `AF_INET` address seen per interface. Per plan §5.7.
    private static func readInterfaceCounters() -> [String: InterfaceCounters] {
        var result: [String: InterfaceCounters] = [:]
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return [:] }
        defer { freeifaddrs(ifaddrsPtr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name != "lo0" else { continue }

            let flags = ptr.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_RUNNING)) != 0
            let family = ptr.pointee.ifa_addr?.pointee.sa_family

            var entry = result[name] ?? InterfaceCounters(name: name, rx: 0, tx: 0, isUp: isUp, localIPAddress: nil)
            entry.isUp = entry.isUp || isUp

            if family == UInt8(AF_LINK) {
                if let data = ptr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    entry.rx = UInt64(data.pointee.ifi_ibytes)
                    entry.tx = UInt64(data.pointee.ifi_obytes)
                }
            } else if family == UInt8(AF_INET), entry.localIPAddress == nil {
                entry.localIPAddress = Self.ipv4String(from: ptr.pointee.ifa_addr)
            }

            result[name] = entry
        }
        return result
    }

    private static func ipv4String(from addr: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            addr, socklen_t(addr.pointee.sa_len),
            &buffer, socklen_t(buffer.count),
            nil, 0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Picks the interface to report on: the actual default-route interface
    /// via `SCDynamicStore`'s "PrimaryInterface", which is what has real
    /// traffic — not a `rx > 0 || tx > 0` check, which is useless in
    /// practice (those are cumulative-since-boot counters, so once *any*
    /// interface has moved *any* byte since boot it satisfies that check
    /// forever; on a Mac docked over Ethernet with Wi-Fi still radio-on,
    /// that previously always misidentified `en0` as "active" via
    /// alphabetic sort regardless of which link actually carried traffic).
    /// Falls back to the lowest-numbered up `enN` interface only if the
    /// primary-interface lookup itself fails.
    private static func pickActiveInterface(from counters: [String: InterfaceCounters]) -> InterfaceCounters? {
        if let primaryName = primaryInterfaceName(), let primary = counters[primaryName], primary.isUp {
            return primary
        }

        return counters.values
            .filter { $0.isUp && $0.name.hasPrefix("en") }
            .sorted { $0.name < $1.name }
            .first
    }

    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Sentry" as CFString, nil, nil) else { return nil }
        guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }
}
