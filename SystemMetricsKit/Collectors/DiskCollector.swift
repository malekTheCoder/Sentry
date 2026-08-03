import Foundation
import IOKit
import IOKit.storage
import SentryKit

/// Volume capacity comes from `URL.resourceValues`; throughput and IOPS come
/// from summing `IOBlockStorageDriver` "Statistics" across every matched
/// device (multiple disks/volumes collapse into one whole-system figure for
/// Phase 1 — see plan §5.6).
public final class DiskCollector: Collector {
    private let volumeURL: URL

    private let readBytesTracker = DeltaTracker()
    private let writeBytesTracker = DeltaTracker()
    private let readOpsTracker = DeltaTracker()
    private let writeOpsTracker = DeltaTracker()

    public init(volumeURL: URL = URL(fileURLWithPath: "/")) {
        self.volumeURL = volumeURL
    }

    public func collect() -> DiskStats? {
        guard let capacity = readCapacity() else { return nil }

        let now = Date()
        var readBytesPerSec: Double?
        var writeBytesPerSec: Double?
        var readIOPS: Double?
        var writeIOPS: Double?

        if let counters = readCumulativeCounters() {
            readBytesPerSec = readBytesTracker.rate(for: counters.bytesRead, at: now)
            writeBytesPerSec = writeBytesTracker.rate(for: counters.bytesWritten, at: now)
            readIOPS = readOpsTracker.rate(for: counters.opsRead, at: now)
            writeIOPS = writeOpsTracker.rate(for: counters.opsWritten, at: now)
        }

        return DiskStats(
            freeBytes: capacity.free,
            totalBytes: capacity.total,
            readBytesPerSec: readBytesPerSec,
            writeBytesPerSec: writeBytesPerSec,
            readIOPS: readIOPS,
            writeIOPS: writeIOPS
        )
    }

    private func readCapacity() -> (free: UInt64, total: UInt64)? {
        guard let values = try? volumeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]) else { return nil }

        // importantUsage accounts for purgeable space the way Finder does —
        // plain volumeAvailableCapacity reads lower than what the user sees.
        guard let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity
        else { return nil }

        return (UInt64(free), UInt64(total))
    }

    private func readCumulativeCounters() -> (bytesRead: UInt64, bytesWritten: UInt64, opsRead: UInt64, opsWritten: UInt64)? {
        let allProperties = IOKitBridge.propertiesForAllServices(matching: kIOBlockStorageDriverClass)
        guard !allProperties.isEmpty else { return nil }

        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var opsRead: UInt64 = 0
        var opsWritten: UInt64 = 0

        for properties in allProperties {
            guard let stats = properties["Statistics"] as? [String: Any] else { continue }
            bytesRead += counterValue(stats["Bytes (Read)"])
            bytesWritten += counterValue(stats["Bytes (Write)"])
            opsRead += counterValue(stats["Operations (Read)"])
            opsWritten += counterValue(stats["Operations (Write)"])
        }

        return (bytesRead, bytesWritten, opsRead, opsWritten)
    }

    /// IOKit statistics values arrive as NSNumber of varying underlying width;
    /// go through NSNumber rather than an `as?` cast to a specific integer type.
    private func counterValue(_ raw: Any?) -> UInt64 {
        guard let number = raw as? NSNumber else { return 0 }
        return number.uint64Value
    }
}
