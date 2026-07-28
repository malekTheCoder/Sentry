import Foundation
import MacStatKit

/// There is no public or private ANE *utilization* percentage — power draw
/// above the idle floor is the industry-standard activity proxy (it's what
/// `powermetrics` itself reports), via IOReport's "Energy Model" → "ANE"
/// channel. Label it "ANE Power" in UI, never "ANE Usage" (plan §5.4).
public final class ANECollector: Collector {
    // Idle ANE power reads as ~0 W but rarely an exact zero (noise floor);
    // treat anything at or below this as "not active" rather than requiring
    // a literal 0. Not derived from any spec — a reasonable judgment call,
    // revisit if real-world sampling shows it's too sensitive/insensitive.
    private static let activeThresholdWatts = 0.05

    public init() {}

    public func collect() -> ANEStats? {
        let energy = SharedEnergySampler.shared.sampleDelta()
        guard let powerWatts = SharedEnergySampler.shared.resolver.powerWatts(
            forMetric: .aneEnergy,
            in: energy.samples,
            elapsedSeconds: energy.elapsedSeconds
        ) else {
            return nil
        }

        return ANEStats(
            powerWatts: powerWatts,
            isActive: powerWatts > Self.activeThresholdWatts
        )
    }
}
