import Foundation

/// Snapshot of network throughput plus (optional) Wi-Fi radio details.
///
/// `rxSessionTotalBytes` / `txSessionTotalBytes` are cumulative bytes observed
/// on the active interface since the collector was created (or since the
/// interface's counters last reset, e.g. on link flap) — not lifetime-since-boot
/// totals.
public struct NetworkStats: Codable, Sendable {
    public var rxBytesPerSec: Double
    public var txBytesPerSec: Double
    public var rxSessionTotalBytes: UInt64
    public var txSessionTotalBytes: UInt64
    public var activeInterface: String?
    public var isWiFi: Bool
    public var localIPAddress: String?
    public var wifiSSID: String?
    public var wifiRSSIdBm: Int?
    public var wifiNoisedBm: Int?
    public var wifiTxRateMbps: Double?

    public init(
        rxBytesPerSec: Double,
        txBytesPerSec: Double,
        rxSessionTotalBytes: UInt64,
        txSessionTotalBytes: UInt64,
        activeInterface: String? = nil,
        isWiFi: Bool = false,
        localIPAddress: String? = nil,
        wifiSSID: String? = nil,
        wifiRSSIdBm: Int? = nil,
        wifiNoisedBm: Int? = nil,
        wifiTxRateMbps: Double? = nil
    ) {
        self.rxBytesPerSec = rxBytesPerSec
        self.txBytesPerSec = txBytesPerSec
        self.rxSessionTotalBytes = rxSessionTotalBytes
        self.txSessionTotalBytes = txSessionTotalBytes
        self.activeInterface = activeInterface
        self.isWiFi = isWiFi
        self.localIPAddress = localIPAddress
        self.wifiSSID = wifiSSID
        self.wifiRSSIdBm = wifiRSSIdBm
        self.wifiNoisedBm = wifiNoisedBm
        self.wifiTxRateMbps = wifiTxRateMbps
    }
}
