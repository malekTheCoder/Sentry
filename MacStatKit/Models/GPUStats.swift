import Foundation

/// Phase 0 skeleton — fields fleshed out in Phase 1 per plan §5.3.
public struct GPUStats: Codable, Sendable {
    public var utilizationPercent: Double?
    public var rendererPercent: Double?
    public var tilerPercent: Double?
    public var vramUsedBytes: UInt64?
    public var frequencyMHz: Double?
    public var powerWatts: Double?

    public init(
        utilizationPercent: Double? = nil,
        rendererPercent: Double? = nil,
        tilerPercent: Double? = nil,
        vramUsedBytes: UInt64? = nil,
        frequencyMHz: Double? = nil,
        powerWatts: Double? = nil
    ) {
        self.utilizationPercent = utilizationPercent
        self.rendererPercent = rendererPercent
        self.tilerPercent = tilerPercent
        self.vramUsedBytes = vramUsedBytes
        self.frequencyMHz = frequencyMHz
        self.powerWatts = powerWatts
    }
}
