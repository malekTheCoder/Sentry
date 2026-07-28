import Foundation

/// Phase 0 skeleton — fields fleshed out in Phase 1 per plan §5.7.
public struct NetworkStats: Codable, Sendable {
    public var rxBytesPerSec: Double
    public var txBytesPerSec: Double
    public var rxTotalBytes: UInt64
    public var txTotalBytes: UInt64
    public var activeInterface: String?
    public var wifiSSID: String?
    public var wifiRSSIdBm: Int?
    public var wifiTxRateMbps: Double?

    public init(
        rxBytesPerSec: Double,
        txBytesPerSec: Double,
        rxTotalBytes: UInt64,
        txTotalBytes: UInt64,
        activeInterface: String? = nil,
        wifiSSID: String? = nil,
        wifiRSSIdBm: Int? = nil,
        wifiTxRateMbps: Double? = nil
    ) {
        self.rxBytesPerSec = rxBytesPerSec
        self.txBytesPerSec = txBytesPerSec
        self.rxTotalBytes = rxTotalBytes
        self.txTotalBytes = txTotalBytes
        self.activeInterface = activeInterface
        self.wifiSSID = wifiSSID
        self.wifiRSSIdBm = wifiRSSIdBm
        self.wifiTxRateMbps = wifiTxRateMbps
    }
}
