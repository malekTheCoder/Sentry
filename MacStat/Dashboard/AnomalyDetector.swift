import Foundation
import MacStatKit

/// Plan §17 Phase 8 stretch: "anomaly detection / baselining." One row of
/// `AnomalyDetector.detect`'s result — a metric whose current value is
/// significantly off its own recent history, not compared against any
/// other Mac or a hardcoded "normal" range (there is no such thing across
/// different machines/workloads; the only honest baseline is a Mac's own
/// past).
struct MetricAnomaly: Equatable, Identifiable {
    var id: String { metricID.rawValue }
    var metricID: MetricID
    var displayName: String
    var currentValue: Double
    var baselineValue: Double
    /// Signed: positive means current is above baseline, negative below.
    var percentDeviation: Double
}

/// Pure comparison logic — deliberately separate from the `HistoryStore`
/// queries that feed it (`DashboardViewModel.refreshAnomalies`), same
/// "pure calculation, impure caller" split `DashboardViewModel.downsample`
/// and `SystemAdvisor.recommend` already use in this codebase, so the
/// threshold logic is testable without a real database.
enum AnomalyDetector {
    /// Deliberately not every metric this app tracks: throughput-shaped
    /// metrics (disk/network bytes-per-second) are naturally bursty by
    /// design — a baseline-deviation check on them would fire on every
    /// large file copy or download, which isn't an "anomaly," it's normal
    /// use. The candidates below are metrics where sustained deviation
    /// from a Mac's own recent normal genuinely means something (thermal
    /// pressure, resource contention, battery wear).
    static let candidateMetrics: [MetricID] = [
        .cpuTotalPercent,
        .memoryPressurePercent,
        .thermalSocTempC,
        .diskUsedPercent,
        .batteryHealthPercent
    ]

    /// How far from baseline (as a percent of the baseline itself) counts
    /// as worth surfacing — picked to sit well above ordinary day-to-day
    /// noise (a Mac's CPU average genuinely does vary 10-15% day to day
    /// with normal usage) without requiring a wild swing to ever fire.
    static let deviationThresholdPercent: Double = 25

    /// A metric needs at least this many days of daily-rollup history
    /// before its baseline is trusted — a 1-2 day-old baseline is mostly
    /// noise, and flagging "anomalies" against it on a fresh install would
    /// make the feature look broken on day one rather than useful.
    static let minimumBaselineDays = 3

    struct Baseline {
        var averageValue: Double
        var sampleDayCount: Int
    }

    /// Sorted by deviation magnitude, largest first — a caller showing only
    /// the top few doesn't need to sort again.
    static func detect(currentValues: [MetricID: Double], baselines: [MetricID: Baseline]) -> [MetricAnomaly] {
        var results: [MetricAnomaly] = []
        for metricID in candidateMetrics {
            guard let current = currentValues[metricID],
                  let baseline = baselines[metricID],
                  baseline.sampleDayCount >= minimumBaselineDays,
                  baseline.averageValue != 0
            else { continue }

            let percentDeviation = (current - baseline.averageValue) / abs(baseline.averageValue) * 100
            guard abs(percentDeviation) >= deviationThresholdPercent else { continue }

            results.append(MetricAnomaly(
                metricID: metricID,
                displayName: metricID.shortLabel,
                currentValue: current,
                baselineValue: baseline.averageValue,
                percentDeviation: percentDeviation
            ))
        }
        return results.sorted { abs($0.percentDeviation) > abs($1.percentDeviation) }
    }
}
