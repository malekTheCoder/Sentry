import Foundation
import MacStatKit

// MARK: - Charted metrics

/// The series the dropdown keeps a rolling window for — one per module card,
/// each backed by a canonical `MetricID` so extraction, units, and theme
/// colors all come from MacStatKit rather than being restated here.
enum ChartMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, ane, memory, disk, network, thermal, power

    var id: String { rawValue }

    /// The metric this card's sparkline plots. Cards whose module exposes
    /// several rates (disk read/write, network rx/tx) chart the primary one
    /// and show the counterpart as a detail row — charting a synthetic
    /// "total" would have no `MetricID`, and therefore no unit, color token,
    /// or history-store equivalent.
    var metricID: MetricID {
        switch self {
        case .cpu: return .cpuTotalPercent
        case .gpu: return .gpuUtilizationPercent
        case .ane: return .anePowerWatts
        case .memory: return .memoryUsedBytes
        case .disk: return .diskReadBytesPerSec
        case .network: return .networkRxBytesPerSec
        case .thermal: return .thermalSocTempC
        case .power: return .batterySystemPowerWatts
        }
    }

    /// `Theme.metricColors` carries roughly one key per module, so ANE and
    /// thermal borrow their nearest sibling's color rather than falling back
    /// to a flat accent for every card.
    var colorID: MetricID {
        switch self {
        case .ane: return .gpuUtilizationPercent
        case .thermal, .power: return .batteryChargePercent
        default: return metricID
        }
    }

    var unit: MetricUnit { metricID.unit }

    var module: MetricModule { metricID.module }

    var title: String { module.displayName }

    /// SF Symbol for the card header. Paired with the text label so meaning is
    /// never carried by color alone (plan §9.4).
    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .ane: return "brain"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .thermal: return "thermometer.medium"
        case .power: return "bolt"
        }
    }

    /// Percentage series get a fixed 0...100 axis so the sparkline shows
    /// absolute load instead of auto-scaling idle noise into a dramatic shape.
    var isPercentage: Bool { unit == .percent }
}

// MARK: - Samples

struct MetricSample: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let value: Double

    /// The timestamp already identifies a sample uniquely within a series,
    /// and `id` is only used for `Identifiable`. Minting a UUID per sample
    /// meant 8 random UUIDs per snapshot forever for no benefit (P6).
    var id: Date { timestamp }

    init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// A metric's rolling window plus the summary stats the cards display.
/// Stats are computed on demand — 60 samples is small enough that caching
/// would cost more in invalidation bugs than it saves in cycles.
struct MetricSeries: Identifiable, Equatable, Sendable {
    let metric: ChartMetric
    private(set) var samples: [MetricSample]

    var id: String { metric.rawValue }

    init(metric: ChartMetric, samples: [MetricSample] = []) {
        self.metric = metric
        self.samples = samples
    }

    var isEmpty: Bool { samples.isEmpty }
    var latest: Double? { samples.last?.value }
    var minimum: Double? { samples.map(\.value).min() }
    var maximum: Double? { samples.map(\.value).max() }

    var average: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0) { $0 + $1.value } / Double(samples.count)
    }

    mutating func append(_ value: Double, at timestamp: Date, limit: Int) {
        samples.append(MetricSample(timestamp: timestamp, value: value))
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
    }
}

// MARK: - View model

/// Passive sink for snapshots. It deliberately does **not** subscribe to
/// `StatsCoordinator`: the AppDelegate owns that stream and forwards into
/// `ingest(_:)`, so opening a second consumer here would duplicate polling
/// (plan §3.2 P3) and make the class untestable without a live coordinator.
@MainActor
final class DropdownViewModel: ObservableObject {
    /// 60 samples is the window plan §8.3 specifies for dropdown charts.
    /// `nonisolated` so it stays usable as a default argument and from view
    /// code without hopping the actor (a main-actor-isolated static constant
    /// is an error in the Swift 6 language mode).
    nonisolated static let historyLimit = 60

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var history: [ChartMetric: MetricSeries] = [:]

    private let historyLimit: Int

    init(historyLimit: Int = DropdownViewModel.historyLimit) {
        self.historyLimit = max(1, historyLimit)
    }

    func ingest(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        let stamp = snapshot.timestamp
        for metric in ChartMetric.allCases {
            // A nil reading appends nothing rather than a zero — a gap in the
            // chart is honest, a flat zero line is a lie (plan §3.2 P5).
            guard let value = Self.value(of: metric, in: snapshot) else { continue }
            // In-place via `default:` rather than copy-out/append/copy-in:
            // the latter leaves two references alive across the mutation, so
            // CoW copies the whole 60-sample buffer for every metric on every
            // tick, forever (P6). `StatusItemView.appendHistory` avoids the
            // same trap for the same reason.
            history[metric, default: MetricSeries(metric: metric)]
                .append(value, at: stamp, limit: historyLimit)
        }
    }

    func series(for metric: ChartMetric) -> MetricSeries? {
        guard let series = history[metric], !series.isEmpty else { return nil }
        return series
    }

    /// Used when the popover reopens after a long gap, where stale samples
    /// would render as a misleading continuous line.
    func reset() {
        snapshot = nil
        history.removeAll()
    }

    // MARK: Extraction

    private static func value(of metric: ChartMetric, in snapshot: SystemSnapshot) -> Double? {
        switch metric {
        case .power:
            // One "power" series, two source fields: what's going in while
            // charging, what's being drawn otherwise.
            if snapshot.battery?.isCharging == true,
               let charging = snapshot.value(for: .batteryChargingWatts) {
                return charging
            }
            return snapshot.value(for: .batterySystemPowerWatts)
        default:
            return snapshot.value(for: metric.metricID)
        }
    }
}
