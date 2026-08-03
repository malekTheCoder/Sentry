import Foundation

/// Volume capacity plus throughput/IOPS deltas across all IOBlockStorageDriver
/// devices. Rate fields are nil on a collector's first sample (no prior
/// reading to diff against) — see plan §5.6.
public struct DiskStats: Codable, Sendable {
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    public var readBytesPerSec: Double?
    public var writeBytesPerSec: Double?
    public var readIOPS: Double?
    public var writeIOPS: Double?

    public init(
        freeBytes: UInt64,
        totalBytes: UInt64,
        readBytesPerSec: Double? = nil,
        writeBytesPerSec: Double? = nil,
        readIOPS: Double? = nil,
        writeIOPS: Double? = nil
    ) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
        self.readIOPS = readIOPS
        self.writeIOPS = writeIOPS
    }
}
