import Foundation

/// Phase 0 skeleton — fields fleshed out in Phase 1 per plan §5.5.
public struct MemoryStats: Codable, Sendable {
    public var usedBytes: UInt64
    public var wiredBytes: UInt64?
    public var compressedBytes: UInt64?
    public var cachedBytes: UInt64?
    public var pressurePercent: Double?
    public var swapUsedBytes: UInt64?
    public var totalBytes: UInt64

    public init(
        usedBytes: UInt64,
        wiredBytes: UInt64? = nil,
        compressedBytes: UInt64? = nil,
        cachedBytes: UInt64? = nil,
        pressurePercent: Double? = nil,
        swapUsedBytes: UInt64? = nil,
        totalBytes: UInt64
    ) {
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.pressurePercent = pressurePercent
        self.swapUsedBytes = swapUsedBytes
        self.totalBytes = totalBytes
    }
}
