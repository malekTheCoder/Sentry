import Foundation

/// Utilization/memory fields come from IOAccelerator "PerformanceStatistics"
/// (plan §5.3). frequencyMHz/powerWatts stay nil until IOReportBridge lands
/// (plan §5.4) — they come from a different IOKit subsystem entirely.
public struct GPUStats: Codable, Sendable {
    public var utilizationPercent: Double?
    public var rendererPercent: Double?
    public var tilerPercent: Double?
    public var vramUsedBytes: UInt64?
    public var vramAllocatedBytes: UInt64?
    public var frequencyMHz: Double?
    public var powerWatts: Double?

    public init(
        utilizationPercent: Double? = nil,
        rendererPercent: Double? = nil,
        tilerPercent: Double? = nil,
        vramUsedBytes: UInt64? = nil,
        vramAllocatedBytes: UInt64? = nil,
        frequencyMHz: Double? = nil,
        powerWatts: Double? = nil
    ) {
        self.utilizationPercent = utilizationPercent
        self.rendererPercent = rendererPercent
        self.tilerPercent = tilerPercent
        self.vramUsedBytes = vramUsedBytes
        self.vramAllocatedBytes = vramAllocatedBytes
        self.frequencyMHz = frequencyMHz
        self.powerWatts = powerWatts
    }
}
