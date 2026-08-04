import Foundation
import SentryKit

// MARK: - Charted metrics

/// The series the dropdown keeps a rolling window for — one per module card,
/// each backed by a canonical `MetricID` so extraction, units, and theme
/// colors all come from SentryKit rather than being restated here.
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
///
/// **Dead-code removal.** This used to also build eight rolling 60-sample
/// `MetricSeries` buffers (one per `ChartMetric`) on every single snapshot,
/// forever — on the app's hottest recurring path — for a `series(for:)`
/// accessor nothing called: the dropdown's per-module cards that once read it
/// (`ModuleCards/ModuleCardStack.swift`, `ModuleCards/MetricCard.swift`) were
/// themselves dead after the "lighter headline-glance layout" redesign (see
/// `DropdownView`'s doc comment) and have been deleted. The Dashboard has its
/// own, separate series machinery (`DashboardViewModel`) and never read this
/// one either — confirmed via grep before removing it. `snapshot` is the only
/// thing still consumed (by `SystemVitals` through `DropdownView`), so that's
/// all that remains.
@MainActor
final class DropdownViewModel: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot?

    /// Backs the CPU vital's top-3-processes detail rows (see
    /// `DropdownProcessList` and `VitalsSection.details(for:)`).
    ///
    /// **Why a second `ProcessMonitor` instance, not the Dashboard's one.**
    /// `AppDelegate` already owns a `ProcessMonitor` and starts/stops it via
    /// `updateProcessMonitorState()` — but that gate is deliberately narrowed
    /// to "main window visible AND Dashboard tab selected"
    /// (`updateProcessMonitorState`'s own doc comment), specifically so the
    /// app's most expensive collector doesn't run for a Dashboard the user
    /// isn't looking at. Widening that gate to "OR the dropdown is open"
    /// would mean editing `AppDelegate.swift`, which is off-limits for this
    /// change (owned by another agent) — so this dropdown gets its own
    /// instance instead, started/stopped by `DropdownView`'s own
    /// `onAppear`/`onDisappear` (see that file), independently of whatever
    /// the Dashboard's instance is doing. The two instances never share
    /// state and don't need to: each already stops itself the moment nobody
    /// is looking at *it*, which is the same "don't pay for what nobody's
    /// looking at" posture `ProcessMonitor`'s own doc comment describes — the
    /// only real cost of a second instance is one extra `ProcessCollector`
    /// enumeration pass on the rare tick where both the dropdown and the
    /// Dashboard happen to be open at once, and nothing at all otherwise.
    ///
    /// `limit: 3` (rather than reusing the Dashboard's 8) because the
    /// dropdown only ever displays `DropdownProcessList.topThree(_:)` — no
    /// point collecting rows this surface will just discard.
    let processMonitor = ProcessMonitor(limit: 3)

    func ingest(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
    }

    /// Used when the popover reopens after a long gap, where a stale snapshot
    /// would render as though it were current.
    func reset() {
        snapshot = nil
    }

    /// Called from `DropdownView.onAppear` — see `processMonitor`'s doc
    /// comment for why this dropdown owns its own start/stop rather than
    /// sharing the Dashboard's gating.
    func startProcessMonitoring() {
        processMonitor.start()
    }

    /// Called from `DropdownView.onDisappear`.
    func stopProcessMonitoring() {
        processMonitor.stop()
    }
}
