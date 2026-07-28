import Foundation

public enum MemoryPressureLevel: Int, Codable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

public struct MemoryStats: Codable, Sendable {
    public var usedBytes: UInt64
    public var appMemoryBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedBytes: UInt64
    public var totalBytes: UInt64
    public var swapUsedBytes: UInt64?
    public var swapTotalBytes: UInt64?
    public var pressureLevel: MemoryPressureLevel?

    public init(
        usedBytes: UInt64,
        appMemoryBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedBytes: UInt64,
        totalBytes: UInt64,
        swapUsedBytes: UInt64? = nil,
        swapTotalBytes: UInt64? = nil,
        pressureLevel: MemoryPressureLevel? = nil
    ) {
        self.usedBytes = usedBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressureLevel = pressureLevel
    }
}
