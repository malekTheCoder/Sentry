import SwiftUI
import MacStatKit

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
        LazyVGrid(columns: columns, spacing: palette.spacing * 1.5) {
            ForEach(Self.order.filter { enabledModules.contains($0.module) }) { metric in
                card(for: metric)
            }
        }
    }

    /// Adaptive with a 320pt floor: at the window's ~900pt default content
    /// width that yields a comfortable 2-column layout (2×320 + spacing),
    /// growing to 3 columns once the window is widened past roughly
    /// 1000-1100pt, and collapsing gracefully to 1 column at the 760pt
    /// `contentMinSize` `HistoryWindowController` enforces. A fixed column
    /// count would either waste width at the default size or crush cards
    /// too narrow to read a chart's y-axis labels once resized down.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: palette.spacing * 1.5)]
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(for metric: ChartMetric) -> some View {
        let samples = series[metric] ?? []
        let headline = MetricFormatting.value(snapshot?.value(for: metric.metricID), metric: metric.metricID)

        switch metric {
        case .cpu:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: cpuSubtitle, samples: samples) {
                MetricDetailRow(label: "E-cores", value: MetricFormatting.percent(snapshot?.cpu?.ecorePercent, decimals: 1))
                MetricDetailRow(label: "P-cores", value: MetricFormatting.percent(snapshot?.cpu?.pcorePercent, decimals: 1))
                MetricDetailRow(label: "Frequency", value: MetricFormatting.value(snapshot?.value(for: .cpuFrequencyMHz), metric: .cpuFrequencyMHz))
                MetricDetailRow(label: "Package power", value: MetricFormatting.watts(snapshot?.cpu?.packagePowerWatts))
            }
        case .gpu:
            DashboardMetricCard(metric: metric, headline: headline, samples: samples) {
                MetricDetailRow(label: "Renderer", value: MetricFormatting.percent(snapshot?.gpu?.rendererPercent, decimals: 1))
                MetricDetailRow(label: "Tiler", value: MetricFormatting.percent(snapshot?.gpu?.tilerPercent, decimals: 1))
                MetricDetailRow(label: "VRAM", value: MetricFormatting.bytes(snapshot?.gpu?.vramUsedBytes))
                MetricDetailRow(label: "Frequency", value: MetricFormatting.value(snapshot?.gpu?.frequencyMHz, metric: .gpuFrequencyMHz))
                MetricDetailRow(label: "Power", value: MetricFormatting.watts(snapshot?.gpu?.powerWatts))
            }
        case .ane:
            // Same "no public ANE utilization" caveat as `ModuleCardStack` —
            // see `ANEStats`'s doc comment.
            DashboardMetricCard(metric: metric, headline: headline, subtitle: "Power draw proxy", samples: samples) {
                MetricDetailRow(label: "Active", value: aneActivity)
            }
        case .memory:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: memorySubtitle, samples: samples) {
                MetricDetailRow(label: "App", value: MetricFormatting.bytes(snapshot?.memory?.appMemoryBytes))
                MetricDetailRow(label: "Wired", value: MetricFormatting.bytes(snapshot?.memory?.wiredBytes))
                MetricDetailRow(label: "Compressed", value: MetricFormatting.bytes(snapshot?.memory?.compressedBytes))
                MetricDetailRow(label: "Cached", value: MetricFormatting.bytes(snapshot?.memory?.cachedBytes))
                MetricDetailRow(label: "Swap", value: MetricFormatting.bytes(snapshot?.memory?.swapUsedBytes))
                MetricDetailRow(label: "Pressure", value: memoryPressure)
            }
        case .disk:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: "Read throughput", samples: samples) {
                MetricDetailRow(label: "Write", value: MetricFormatting.bytesPerSecond(snapshot?.disk?.writeBytesPerSec))
                MetricDetailRow(label: "Read IOPS", value: MetricFormatting.value(snapshot?.disk?.readIOPS, metric: .diskReadIOPS))
                MetricDetailRow(label: "Write IOPS", value: MetricFormatting.value(snapshot?.disk?.writeIOPS, metric: .diskWriteIOPS))
                MetricDetailRow(label: "Free", value: MetricFormatting.bytes(snapshot?.disk?.freeBytes))
                MetricDetailRow(label: "Used", value: MetricFormatting.percent(snapshot?.value(for: .diskUsedPercent), decimals: 1))
            }
        case .network:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: networkSubtitle, samples: samples) {
                MetricDetailRow(label: "Upload", value: MetricFormatting.bytesPerSecond(snapshot?.network?.txBytesPerSec))
                MetricDetailRow(label: "Session ↓", value: MetricFormatting.bytes(snapshot?.network?.rxSessionTotalBytes))
                MetricDetailRow(label: "Session ↑", value: MetricFormatting.bytes(snapshot?.network?.txSessionTotalBytes))
                MetricDetailRow(label: "IP", value: snapshot?.network?.localIPAddress ?? MetricFormatting.placeholder)
                MetricDetailRow(label: "Signal", value: MetricFormatting.value(snapshot?.network?.wifiRSSIdBm.map { Double($0) }, metric: .networkWifiRSSIdBm))
                MetricDetailRow(label: "Link rate", value: MetricFormatting.value(snapshot?.network?.wifiTxRateMbps, metric: .networkWifiTxRateMbps))
            }
        case .thermal:
            DashboardMetricCard(metric: metric, headline: headline, subtitle: thermalSubtitle, samples: samples) {
                MetricDetailRow(label: "Throttling", value: thermalThrottling)
                ForEach(Array(fanRPMs.enumerated()), id: \.offset) { index, rpm in
                    MetricDetailRow(label: "Fan \(index + 1)", value: "\(Int(rpm.rounded())) RPM")
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
            parts.append(String(format: "load %.2f", load))
        }
        if let processes = snapshot?.cpu?.processCount {
            parts.append("\(processes) procs")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var memorySubtitle: String? {
        guard let memory = snapshot?.memory, memory.totalBytes > 0 else { return nil }
        let used = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        return "\(MetricFormatting.percent(used)) of \(MetricFormatting.bytes(memory.totalBytes))"
    }

    private var memoryPressure: String {
        guard let level = snapshot?.memory?.pressureLevel else { return MetricFormatting.placeholder }
        switch level {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    private var aneActivity: String {
        guard let isActive = snapshot?.ane?.isActive else { return MetricFormatting.placeholder }
        return isActive ? "Yes" : "No"
    }

    private var networkSubtitle: String? {
        guard let network = snapshot?.network else { return nil }
        if let ssid = network.wifiSSID, !ssid.isEmpty { return ssid }
        return network.activeInterface
    }

    private var thermalSubtitle: String? {
        snapshot?.thermal.map { $0.pressureLevel.displayName + " pressure" }
    }

    private var thermalThrottling: String {
        guard let thermal = snapshot?.thermal else { return MetricFormatting.placeholder }
        return thermal.isThrottling ? "Yes" : "No"
    }

    private var fanRPMs: [Double] {
        snapshot?.thermal?.fanRPMs ?? []
    }
}

// MARK: - Card shell

/// One grid cell: header (icon, title, subtitle, live headline value), a
/// full-size `DashboardChart`, then the caller-supplied detail rows. Unlike
/// `MetricCard`, there's no collapse/expand toggle — a grid cell isn't
/// competing with a footer for vertical space the way a dropdown card list
/// is, so there's no reason to hide a card's own content by default.
private struct DashboardMetricCard<Detail: View>: View {
    @Environment(\.themePalette) private var palette

    let metric: ChartMetric
    let headline: String
    var subtitle: String? = nil
    let samples: DashboardViewModel.RangedSamples
    @ViewBuilder let detail: () -> Detail

    private var tint: Color { palette.metricColor(metric.colorID) }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            DashboardChart(samples: samples, tint: tint, metricTitle: metric.title, height: 140)
            detail()
        }
        .padding(palette.spacing * 1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: palette.spacing) {
            Image(systemName: metric.symbolName)
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                    .font(palette.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(palette.font(size: 10))
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: palette.spacing)
            Text(headline)
                .font(palette.font(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title), \(headline)")
    }
}
