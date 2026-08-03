import Foundation

/// `IOReportBridge.sampleDelta` blocks the calling thread for ~1s (the
/// plan's noise floor for a meaningful energy-delta window). GPU power, ANE
/// power, and CPU package power all come from the same "Energy Model"
/// subscription — if each collector opened its own subscription and sampled
/// independently, a poll tick that calls more than one would block for
/// several seconds instead of ~1s for no reason.
///
/// This holds one subscription plus one `ChannelResolver`, and caches the
/// last sample for a short TTL so collectors invoked back-to-back within the
/// same poll tick share one blocking sample instead of each taking their
/// own. All access is serialized through a private queue: `StatsCoordinator`
/// dispatches provider calls off its own timer queue precisely so a slow
/// IOReport sample on one tier can't stall another tier's ticks, which means
/// two tiers really can call into this singleton at genuinely the same time
/// — this can't rely on "only ever called from one serial queue" the way an
/// earlier version of this file did.
final class SharedEnergySampler {
    static let shared = SharedEnergySampler()

    let resolver = ChannelResolver()

    // Comfortably covers "a few collectors called in quick succession within
    // one poll tick" without going stale enough to matter for a metric
    // that's only ever polled on the medium/slow tier (§8.4).
    private static let cacheTTL: TimeInterval = 2.0

    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.sharedenergysampler")

    private var subscription: IOReportSubscription?

    private var cachedSamples: [IOReportChannelSample] = []
    private var cachedElapsedSeconds: TimeInterval = IOReportBridge.minimumSampleInterval
    private var cachedAt: Date?

    private init() {}

    /// Returns the most recent energy-delta sample set, taking a fresh one
    /// (blocking the calling thread for `interval`, floored at the bridge's
    /// minimum) if the cache is stale or empty. Empty array if IOReport is
    /// unavailable. A failed subscription attempt is retried on the next
    /// call rather than latched permanently — a transient failure (resource
    /// pressure at launch, timing) shouldn't disable GPU/ANE power for the
    /// rest of the process's lifetime with no way to recover.
    func sampleDelta(over interval: TimeInterval = IOReportBridge.minimumSampleInterval)
        -> (samples: [IOReportChannelSample], elapsedSeconds: TimeInterval)
    {
        queue.sync {
            if let cachedAt, Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
                return (cachedSamples, cachedElapsedSeconds)
            }

            if subscription == nil {
                subscription = IOReportBridge.shared.subscribe(toGroup: "Energy Model")
            }
            guard let subscription else { return ([], interval) }

            let result = IOReportBridge.shared.sampleDelta(subscription, over: interval)

            cachedSamples = result.samples
            cachedElapsedSeconds = result.elapsedSeconds
            cachedAt = Date()
            return result
        }
    }
}
