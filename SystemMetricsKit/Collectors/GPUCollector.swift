import Foundation
import IOKit
import MacStatKit

/// Reads GPU utilization/memory from the first "IOAccelerator" service that
/// exposes a "PerformanceStatistics" dict (plan §5.3). Not every matched
/// service has one (e.g. auxiliary/display-only accelerator entries), so we
/// keep scanning `propertiesForAllServices` results until we find one that
/// does, rather than assuming the first match is the right one.
///
/// GPU frequency comes from IOReport DVFS residency, which isn't
/// implemented yet (plan §5.2/§5.3 note this needs separate, more
/// speculative `voltage-states` parsing) — `frequencyMHz` stays nil. Power
/// comes from `IOReportBridge`'s "Energy Model" → "GPU" channel via the
/// shared sampler (see `SharedEnergySampler`).
public final class GPUCollector: Collector {
    public init() {}

    public func collect() -> GPUStats? {
        // Key names vary slightly by GPU family (Apple Silicon vs AMD/Intel
        // discrete); map every key defensively rather than assuming presence.
        // IOAccelerator stats and IOReport power come from two independent
        // subsystems — one failing shouldn't suppress the other's valid
        // data (P5), so only bail if *both* come up empty.
        let stats = firstPerformanceStatistics()

        let energy = SharedEnergySampler.shared.sampleDelta()
        let powerWatts = SharedEnergySampler.shared.resolver.powerWatts(
            forMetric: .gpuEnergy,
            in: energy.samples,
            elapsedSeconds: energy.elapsedSeconds
        )

        guard stats != nil || powerWatts != nil else { return nil }

        return GPUStats(
            utilizationPercent: stats.flatMap { doubleValue($0["Device Utilization %"]) },
            rendererPercent: stats.flatMap { doubleValue($0["Renderer Utilization %"]) },
            tilerPercent: stats.flatMap { doubleValue($0["Tiler Utilization %"]) },
            vramUsedBytes: stats.flatMap { uint64Value($0["In use system memory"]) },
            vramAllocatedBytes: stats.flatMap { uint64Value($0["Alloc system memory"]) },
            powerWatts: powerWatts
        )
    }

    private func firstPerformanceStatistics() -> [String: Any]? {
        let allProperties = IOKitBridge.propertiesForAllServices(matching: "IOAccelerator")
        for properties in allProperties {
            if let stats = properties["PerformanceStatistics"] as? [String: Any] {
                return stats
            }
        }
        return nil
    }

    /// IOKit statistics values arrive as NSNumber of varying underlying width;
    /// go through NSNumber rather than an `as?` cast to a specific numeric type.
    private func doubleValue(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        return number.doubleValue
    }

    private func uint64Value(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber else { return nil }
        return number.uint64Value
    }
}
