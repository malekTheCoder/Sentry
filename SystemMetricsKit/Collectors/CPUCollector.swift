import Foundation
import SentryKit

/// Utilization from `host_processor_info` tick deltas, plus E-core/P-core
/// split, load average, and process count.
///
/// Ticks are `UInt32` and wrap; deltas use `&-` (wrapping subtraction) rather
/// than `DeltaTracker` since CPU % is a busy/total ratio, not a rate.
public final class CPUCollector: Collector {
    private var previousTicks: [CPUTicks]?

    // Cached at init — perf-level core counts don't change at runtime.
    private let performanceCoreCount: Int
    private let efficiencyCoreCount: Int

    public init() {
        performanceCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }

    public func collect() -> CPUStats? {
        let ticks = MachHostBridge.readPerCoreTicks()
        guard !ticks.isEmpty else { return nil }

        defer { previousTicks = ticks }

        guard let previous = previousTicks, previous.count == ticks.count else {
            // First sample (or core count changed) — no delta available yet.
            return CPUStats(
                totalPercent: 0,
                perCorePercent: Array(repeating: 0, count: ticks.count),
                loadAverage1m: MachHostBridge.loadAverage1m(),
                processCount: MachHostBridge.processCount()
            )
        }

        var perCorePercent: [Double] = []
        perCorePercent.reserveCapacity(ticks.count)
        var totalBusy: UInt64 = 0
        var totalAll: UInt64 = 0

        for i in 0..<ticks.count {
            let curr = ticks[i]
            let prev = previous[i]

            let dUser = UInt64(curr.user &- prev.user)
            let dSystem = UInt64(curr.system &- prev.system)
            let dNice = UInt64(curr.nice &- prev.nice)
            let dIdle = UInt64(curr.idle &- prev.idle)

            let busy = dUser + dSystem + dNice
            let all = busy + dIdle

            perCorePercent.append(all > 0 ? Double(busy) / Double(all) * 100.0 : 0)
            totalBusy += busy
            totalAll += all
        }

        let totalPercent = totalAll > 0 ? Double(totalBusy) / Double(totalAll) * 100.0 : 0

        // Core ordering (E-cores first vs P-cores first) is unverified —
        // plan §19 flags this as needing empirical confirmation per Mac
        // model. Assumes E-cores occupy the first `efficiencyCoreCount`
        // indices, matching current-generation Apple Silicon as observed,
        // but this is not guaranteed by any documented API.
        var ecorePercent: Double?
        var pcorePercent: Double?
        if efficiencyCoreCount > 0, performanceCoreCount > 0,
           efficiencyCoreCount + performanceCoreCount == perCorePercent.count {
            let eSlice = perCorePercent[0..<efficiencyCoreCount]
            let pSlice = perCorePercent[efficiencyCoreCount...]
            ecorePercent = eSlice.reduce(0, +) / Double(eSlice.count)
            pcorePercent = pSlice.reduce(0, +) / Double(pSlice.count)
        }

        return CPUStats(
            totalPercent: totalPercent,
            perCorePercent: perCorePercent,
            ecorePercent: ecorePercent,
            pcorePercent: pcorePercent,
            loadAverage1m: MachHostBridge.loadAverage1m(),
            processCount: MachHostBridge.processCount()
        )
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
