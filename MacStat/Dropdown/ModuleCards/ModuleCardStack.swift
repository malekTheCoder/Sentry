import SwiftUI
import MacStatKit

/// Builds the per-module cards (plan §8.3 item 4) from a snapshot. Kept out of
/// `DropdownView` so the root view stays a layout shell and each module's
/// detail rows live next to each other.
struct ModuleCardStack: View {
    @Environment(\.themePalette) private var palette

    let snapshot: SystemSnapshot?
    let history: [ChartMetric: MetricSeries]
    /// Which modules the user turned on in the Modules settings pane.
    /// Without this filter, toggling a module off in Settings had no
    /// observable effect anywhere in the app — the toggle existed but
    /// nothing downstream ever read it.
    let enabledModules: Set<MetricModule>

    /// Card order follows the plan's module listing.
    private static let order: [ChartMetric] = [.cpu, .gpu, .ane, .memory, .disk, .network, .thermal]

    var body: some View {
        VStack(spacing: palette.spacing) {
            ForEach(Self.order.filter { enabledModules.contains($0.module) }) { metric in
                card(for: metric)
            }
        }
    }

    @ViewBuilder
    private func card(for metric: ChartMetric) -> some View {
        let series = history[metric]
        let headline = MetricFormatting.seriesValue(series?.latest, metric: metric)

        switch metric {
        case .cpu:
            MetricCard(metric: metric, series: series, headlineValue: headline, subtitle: cpuSubtitle) {
                MetricDetailRow(label: "E-cores", value: MetricFormatting.percent(snapshot?.cpu?.ecorePercent, decimals: 1))
                MetricDetailRow(label: "P-cores", value: MetricFormatting.percent(snapshot?.cpu?.pcorePercent, decimals: 1))
                MetricDetailRow(label: "Frequency", value: MetricFormatting.value(snapshot?.value(for: .cpuFrequencyMHz), metric: .cpuFrequencyMHz))
                MetricDetailRow(label: "Package power", value: MetricFormatting.watts(snapshot?.cpu?.packagePowerWatts))
            }
        case .gpu:
            MetricCard(metric: metric, series: series, headlineValue: headline) {
                MetricDetailRow(label: "Renderer", value: MetricFormatting.percent(snapshot?.gpu?.rendererPercent, decimals: 1))
                MetricDetailRow(label: "Tiler", value: MetricFormatting.percent(snapshot?.gpu?.tilerPercent, decimals: 1))
                MetricDetailRow(label: "VRAM", value: MetricFormatting.bytes(snapshot?.gpu?.vramUsedBytes))
                MetricDetailRow(label: "Frequency", value: MetricFormatting.value(snapshot?.gpu?.frequencyMHz, metric: .gpuFrequencyMHz))
                MetricDetailRow(label: "Power", value: MetricFormatting.watts(snapshot?.gpu?.powerWatts))
            }
        case .ane:
            // No public ANE utilization exists — power above the idle floor is
            // the activity proxy, so this card is labeled in watts on purpose
            // (see `ANEStats`' doc comment).
            MetricCard(metric: metric, series: series, headlineValue: headline, subtitle: "Power draw proxy") {
                MetricDetailRow(label: "Active", value: aneActivity)
            }
        case .memory:
            MetricCard(metric: metric, series: series, headlineValue: headline, subtitle: memorySubtitle) {
                MetricDetailRow(label: "App", value: MetricFormatting.bytes(snapshot?.memory?.appMemoryBytes))
                MetricDetailRow(label: "Wired", value: MetricFormatting.bytes(snapshot?.memory?.wiredBytes))
                MetricDetailRow(label: "Compressed", value: MetricFormatting.bytes(snapshot?.memory?.compressedBytes))
                MetricDetailRow(label: "Cached", value: MetricFormatting.bytes(snapshot?.memory?.cachedBytes))
                MetricDetailRow(label: "Swap", value: MetricFormatting.bytes(snapshot?.memory?.swapUsedBytes))
                MetricDetailRow(label: "Pressure", value: memoryPressure)
            }
        case .disk:
            MetricCard(metric: metric, series: series, headlineValue: headline, subtitle: "Read throughput") {
                MetricDetailRow(label: "Write", value: MetricFormatting.bytesPerSecond(snapshot?.disk?.writeBytesPerSec))
                MetricDetailRow(label: "Read IOPS", value: MetricFormatting.value(snapshot?.disk?.readIOPS, metric: .diskReadIOPS))
                MetricDetailRow(label: "Write IOPS", value: MetricFormatting.value(snapshot?.disk?.writeIOPS, metric: .diskWriteIOPS))
                MetricDetailRow(label: "Free", value: MetricFormatting.bytes(snapshot?.disk?.freeBytes))
                MetricDetailRow(label: "Used", value: MetricFormatting.percent(snapshot?.value(for: .diskUsedPercent), decimals: 1))
            }
        case .network:
            MetricCard(metric: metric, series: series, headlineValue: headline, subtitle: networkSubtitle) {
                MetricDetailRow(label: "Upload", value: MetricFormatting.bytesPerSecond(snapshot?.network?.txBytesPerSec))
                MetricDetailRow(label: "Session ↓", value: MetricFormatting.bytes(snapshot?.network?.rxSessionTotalBytes))
                MetricDetailRow(label: "Session ↑", value: MetricFormatting.bytes(snapshot?.network?.txSessionTotalBytes))
                MetricDetailRow(label: "IP", value: snapshot?.network?.localIPAddress ?? MetricFormatting.placeholder)
                MetricDetailRow(label: "Signal", value: MetricFormatting.value(snapshot?.network?.wifiRSSIdBm.map(Double.init), metric: .networkWifiRSSIdBm))
                MetricDetailRow(label: "Link rate", value: MetricFormatting.value(snapshot?.network?.wifiTxRateMbps, metric: .networkWifiTxRateMbps))
            }
        case .thermal:
            MetricCard(metric: metric, series: series, headlineValue: headline, subtitle: thermalSubtitle) {
                MetricDetailRow(label: "Throttling", value: thermalThrottling)
                ForEach(Array(fanRPMs.enumerated()), id: \.offset) { index, rpm in
                    MetricDetailRow(label: "Fan \(index + 1)", value: "\(Int(rpm.rounded())) RPM")
                }
            }
        case .power:
            // Power lives in the battery hero card, not as a module card.
            EmptyView()
        }
    }

    // MARK: Subtitles / derived text

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

extension ThermalStats.PressureLevel {
    var displayName: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}
