import SwiftUI
import SentryKit

/// The Dashboard's per-module grid — one detail card per enabled
/// `MetricModule`, mirroring `ModuleCardStack`'s per-module `switch` (same
/// `MetricDetailRow` calls, same `MetricFormatting` calls, same detail
/// fields) but laid out as a `LazyVGrid` instead of a single scrolling
/// `VStack`.
///
/// **Why this doesn't reuse `ModuleCardStack` directly:** the two views are
/// built around different chart primitives on purpose —
/// `ModuleCardStack`/`MetricCard` plot `DropdownViewModel`'s 60-sample
/// in-memory `MetricSeries` via `SparklineChart`, while this grid plots
/// `DashboardViewModel`'s `HistoryStore`-backed `RangedSamples` via
/// `DashboardChart`. Those aren't interchangeable inputs, so the two views'
/// headers/charts genuinely can't share code. The *detail rows* per module
/// (E-cores/P-cores, GPU renderer/tiler, disk read IOPS, etc.) read the same
/// `SystemSnapshot` fields the same way in both places, though, so this
/// grid's `switch` deliberately mirrors `ModuleCardStack.card(for:)`'s
/// row-by-row — if a module's detail rows change there, the same edit
/// belongs here too.
///
/// **Why no 480pt cap / no `ScrollView` here:** the dropdown caps its card
/// list because it lives inside a fixed-height popover with its own footer
/// below it; `DashboardGrid` is assumed to already be inside whatever
/// `ScrollView` the root `DashboardView` provides, so adding a second,
/// nested scroll container here would just fight the outer one for gesture
/// ownership.
struct DashboardGrid: View {
    @Environment(\.themePalette) private var palette

    let snapshot: SystemSnapshot?
    /// Keyed the same way `DashboardViewModel.series` is — absent means "not
    /// queried" (module disabled, or `refresh()` hasn't run yet), not
    /// "queried and empty". Each card's `DashboardChart` treats a missing
    /// key the same as an empty array; both render the chart's own empty
    /// state rather than this view special-casing `nil`.
    let series: [ChartMetric: DashboardViewModel.RangedSamples]
    /// Expected spacing between the points of each entry in `series`, from
    /// `DashboardViewModel.expectedCadence` — see that property for how it is
    /// derived. Keyed identically, with the same "absent means not queried"
    /// contract; a card with no entry falls back to the median spacing of its
    /// own points.
    let expectedCadence: [ChartMetric: TimeInterval]
    /// Same set `DropdownView`/`ModuleCardStack` filter against — a module
    /// the user turned off in Settings shouldn't reappear here just because
    /// history for it still exists in the database.
    let enabledModules: Set<MetricModule>

    /// Same module ordering as `ModuleCardStack`, minus `.power` — power
    /// lives in `BatteryHeroCard`/`BatteryHealthTrendCard` here too, not as
    /// a grid card, for the same reason `ModuleCardStack.card(for:)` renders
    /// `EmptyView()` for it.
    private static let order: [ChartMetric] = [.cpu, .gpu, .ane, .memory, .disk, .network, .thermal]

    var body: some View {
        LazyVGrid(columns: columns, spacing: palette.spacingBlock) {
            ForEach(Self.order.filter { enabledModules.contains($0.module) }) { metric in
                card(for: metric)
            }
        }
    }

    /// Adaptive with a 320pt floor: at the window's ~900pt default content
    /// width that yields a comfortable 2-column layout (2×320 + spacing),
    /// growing to 3 columns once the window is widened past roughly
    /// 1000-1100pt, and collapsing gracefully toward fewer columns at the
    /// 860pt `contentMinSize` `MainWindowController` enforces. A fixed column
    /// count would either waste width at the default size or crush cards
    /// too narrow to read a chart's y-axis labels once resized down.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: palette.spacingBlock)]
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(for metric: ChartMetric) -> some View {
        let samples = series[metric] ?? []
        let seriesCadence = expectedCadence[metric]
        let headline = MetricFormatting.value(snapshot?.value(for: metric.metricID), metric: metric.metricID)

        switch metric {
        case .cpu:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: cpuSubtitle, samples: samples, cadence: seriesCadence) {
                MetricDetailRow(label: String(localized: "E-cores"), value: MetricFormatting.percent(snapshot?.cpu?.ecorePercent, decimals: 1))
                MetricDetailRow(label: String(localized: "P-cores"), value: MetricFormatting.percent(snapshot?.cpu?.pcorePercent, decimals: 1))
                MetricDetailRow(label: String(localized: "Frequency"), value: MetricFormatting.value(snapshot?.value(for: .cpuFrequencyMHz), metric: .cpuFrequencyMHz))
                MetricDetailRow(label: String(localized: "Package power"), value: MetricFormatting.watts(snapshot?.cpu?.packagePowerWatts))
            }
        case .gpu:
            DashboardMetricCard(metric: metric, headline: headline, samples: samples, cadence: seriesCadence) {
                MetricDetailRow(label: String(localized: "Renderer"), value: MetricFormatting.percent(snapshot?.gpu?.rendererPercent, decimals: 1))
                MetricDetailRow(label: String(localized: "Tiler"), value: MetricFormatting.percent(snapshot?.gpu?.tilerPercent, decimals: 1))
                MetricDetailRow(label: String(localized: "VRAM"), value: MetricFormatting.bytes(snapshot?.gpu?.vramUsedBytes))
                MetricDetailRow(label: String(localized: "Frequency"), value: MetricFormatting.value(snapshot?.gpu?.frequencyMHz, metric: .gpuFrequencyMHz))
                MetricDetailRow(label: String(localized: "Power"), value: MetricFormatting.watts(snapshot?.gpu?.powerWatts))
            }
        case .ane:
            // Same "no public ANE utilization" caveat as `ModuleCardStack` —
            // see `ANEStats`'s doc comment.
            DashboardMetricCard(metric: metric, headline: headline, subtitle: String(localized: "Power draw proxy"), samples: samples, cadence: seriesCadence) {
                MetricDetailRow(label: String(localized: "Active"), value: aneActivity)
            }
        case .memory:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: memorySubtitle, samples: samples, cadence: seriesCadence) {
                MetricDetailRow(label: String(localized: "App"), value: MetricFormatting.bytes(snapshot?.memory?.appMemoryBytes))
                MetricDetailRow(label: String(localized: "Wired"), value: MetricFormatting.bytes(snapshot?.memory?.wiredBytes))
                MetricDetailRow(label: String(localized: "Compressed"), value: MetricFormatting.bytes(snapshot?.memory?.compressedBytes))
                MetricDetailRow(label: String(localized: "Cached"), value: MetricFormatting.bytes(snapshot?.memory?.cachedBytes))
                MetricDetailRow(label: String(localized: "Swap"), value: MetricFormatting.bytes(snapshot?.memory?.swapUsedBytes))
                MetricDetailRow(label: String(localized: "Pressure"), value: memoryPressure)
            }
        case .disk:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: String(localized: "Read throughput"), samples: samples, cadence: seriesCadence) {
                MetricDetailRow(label: String(localized: "Write"), value: MetricFormatting.bytesPerSecond(snapshot?.disk?.writeBytesPerSec))
                MetricDetailRow(label: String(localized: "Read IOPS"), value: MetricFormatting.value(snapshot?.disk?.readIOPS, metric: .diskReadIOPS))
                MetricDetailRow(label: String(localized: "Write IOPS"), value: MetricFormatting.value(snapshot?.disk?.writeIOPS, metric: .diskWriteIOPS))
                MetricDetailRow(label: String(localized: "Free"), value: MetricFormatting.bytes(snapshot?.disk?.freeBytes))
                MetricDetailRow(label: String(localized: "Used"), value: MetricFormatting.percent(snapshot?.value(for: .diskUsedPercent), decimals: 1))
            }
        case .network:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: networkSubtitle, samples: samples, cadence: seriesCadence) {
                MetricDetailRow(label: String(localized: "Upload"), value: MetricFormatting.bytesPerSecond(snapshot?.network?.txBytesPerSec))
                MetricDetailRow(label: String(localized: "Session ↓"), value: MetricFormatting.bytes(snapshot?.network?.rxSessionTotalBytes))
                MetricDetailRow(label: String(localized: "Session ↑"), value: MetricFormatting.bytes(snapshot?.network?.txSessionTotalBytes))
                MetricDetailRow(label: String(localized: "IP"), value: snapshot?.network?.localIPAddress ?? MetricFormatting.placeholder)
                MetricDetailRow(label: String(localized: "Signal"), value: MetricFormatting.value(snapshot?.network?.wifiRSSIdBm.map { Double($0) }, metric: .networkWifiRSSIdBm))
                MetricDetailRow(label: String(localized: "Link rate"), value: MetricFormatting.value(snapshot?.network?.wifiTxRateMbps, metric: .networkWifiTxRateMbps))
            }
        case .thermal:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: thermalSubtitle, samples: samples, cadence: seriesCadence) {
                MetricDetailRow(label: String(localized: "Throttling"), value: thermalThrottling)
                ForEach(Array(fanRPMs.enumerated()), id: \.offset) { index, rpm in
                    MetricDetailRow(label: String(localized: "Fan \(String(index + 1))"), value: String(localized: "\(String(Int(rpm.rounded()))) RPM"))
                }
            }
        case .power:
            // See the type doc comment — power is charted in
            // `BatteryHeroCard`/`BatteryHealthTrendCard`, not here.
            EmptyView()
        }
    }

    // MARK: Subtitles / derived text
    //
    // Byte-for-byte the same derivations `ModuleCardStack` uses — see that
    // file if these ever need to change, and change both together.

    private var cpuSubtitle: String? {
        var parts: [String] = []
        if let load = snapshot?.cpu?.loadAverage1m {
            // Number formatted first so the catalog key is "load %@" — a
            // translatable word next to a plain placeholder, instead of a
            // `String(format:)` no translator ever sees.
            let loadText = String(format: "%.2f", load)
            parts.append(String(localized: "load \(loadText)"))
        }
        if let processes = snapshot?.cpu?.processCount {
            let processesText = String(processes)
            parts.append(String(localized: "\(processesText) procs"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var memorySubtitle: String? {
        guard let memory = snapshot?.memory, memory.totalBytes > 0 else { return nil }
        let used = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        return String(localized: "\(MetricFormatting.percent(used)) of \(MetricFormatting.bytes(memory.totalBytes))")
    }

    private var memoryPressure: String {
        guard let level = snapshot?.memory?.pressureLevel else { return MetricFormatting.placeholder }
        switch level {
        case .normal: return String(localized: "Normal")
        case .warning: return String(localized: "Warning")
        case .critical: return String(localized: "Critical")
        }
    }

    private var aneActivity: String {
        guard let isActive = snapshot?.ane?.isActive else { return MetricFormatting.placeholder }
        return isActive ? String(localized: "Yes") : String(localized: "No")
    }

    private var networkSubtitle: String? {
        guard let network = snapshot?.network else { return nil }
        if let ssid = network.wifiSSID, !ssid.isEmpty { return ssid }
        return network.activeInterface
    }

    private var thermalSubtitle: String? {
        snapshot?.thermal.map { String(localized: "\($0.pressureLevel.displayName) pressure") }
    }

    private var thermalThrottling: String {
        guard let thermal = snapshot?.thermal else { return MetricFormatting.placeholder }
        return thermal.isThrottling ? String(localized: "Yes") : String(localized: "No")
    }

    private var fanRPMs: [Double] {
        snapshot?.thermal?.fanRPMs ?? []
    }
}

// MARK: - Card shell

/// One grid cell, per the Nocturne Dashboard mock: a secondary-color label
/// with a small module-tinted status dot, a large SF Mono headline value, a
/// 36px mini sparkline tinted in the module's own color, then the caller's
/// subtitle/detail rows below for the depth the static mock doesn't show but
/// this card already had before the redesign pass. Unlike `MetricCard`,
/// there's no collapse/expand toggle — a grid cell isn't competing with a
/// footer for vertical space the way a dropdown card list is, so there's no
/// reason to hide a card's own content by default.
private struct DashboardMetricCard<Detail: View>: View {
    @Environment(\.themePalette) private var palette

    let metric: ChartMetric
    let headline: String
    var subtitle: String? = nil
    let samples: DashboardViewModel.RangedSamples
    let cadence: TimeInterval?
    @ViewBuilder let detail: () -> Detail

    private var tint: Color { palette.metricColor(metric.colorID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Text(headline)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            DashboardChart(
                samples: samples,
                tint: tint,
                metricTitle: metric.title,
                unit: metric.unit,
                expectedCadence: cadence,
                height: 36,
                compact: true
            )
                .padding(.top, 2)
            if let subtitle {
                Text(subtitle)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                detail()
            }
            .padding(.top, subtitle == nil ? 6 : 2)
        }
        // The one place boxes survive the de-carding: a chart wants a plot
        // area. Fill only — the border went with the rest of the chrome.
        .quietCard(palette)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title), \(headline)")
    }

    private var header: some View {
        HStack(spacing: palette.spacing) {
            Text(metric.title)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: palette.spacing)
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
        }
    }
}
