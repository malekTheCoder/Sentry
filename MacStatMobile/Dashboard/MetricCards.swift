import SwiftUI
import MacStatKit

/// Plan §12.1's 7 metric cards: "CPU, GPU, ANE, Memory, Disk, Network,
/// Thermals." Each is a headline value plus 2-4 detail rows, echoing the
/// level of detail `MacStat/Dropdown/ModuleCards/MetricCard.swift` shows on
/// the Mac (title + headline + detail rows) without that card's sparkline —
/// `DashboardViewModel` only exposes `latestSnapshot`, a single point in
/// time, not the rolling `MetricSeries` history the Mac dropdown charts.
///
/// **Why one generic card type instead of 7 bespoke views.** Every card here
/// is structurally identical (icon + title, headline value, N label/value
/// rows) and differs only in *which* fields it reads off `SystemSnapshot`'s
/// sub-structs. `DashboardMetricCard` holds that shape once; the 7
/// `static func` builders below are the only place that touches
/// `CPUStats`/`GPUStats`/etc. directly, each producing a
/// `DashboardMetricCard` from an optional sub-struct. A nil sub-struct
/// (module unsupported on this Mac, or a snapshot taken before that
/// collector ran) renders "Unavailable" for the headline and every row —
/// never a fabricated zero (P5) — via `unavailable(title:systemImage:)`.

// MARK: - DashboardMetricCard

struct DashboardMetricCard: View {
    @Environment(\.themePalette) private var palette

    let title: String
    let systemImage: String
    let tint: Color
    /// nil headline means the whole module is unavailable; renders
    /// `MetricFormatting.placeholder` rather than an empty string so the
    /// layout doesn't collapse.
    let headlineValue: String
    let rows: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            // Nocturne redesign spec: "compact style: 10px uppercase label +
            // small colored status dot, 16px SF Mono value." The dot replaces
            // the previous SF Symbol as the color cue (a colored dot reads
            // faster at this size than a tinted glyph), and the headline
            // moves to explicit `design: .monospaced` (true SF Mono) at 16px
            // rather than `.monospacedDigit()` on the system font, matching
            // every other "big numeric readout" on this tab.
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(palette.font(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
            }
            Text(headlineValue)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
            if rows.isEmpty {
                Text("Unavailable")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows, id: \.label) { row in
                        DashboardDetailRow(label: row.label, value: row.value)
                    }
                }
            }
        }
        .padding(palette.spacing * 1.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
    }
}

// MARK: - Per-module builders

/// Builds the 7 metric cards from a `SystemSnapshot?`. A `nil` snapshot (no
/// data has arrived yet) and a non-nil snapshot with a `nil` sub-struct
/// (module unsupported/not yet reported) are handled the same way here —
/// both fall through to `MetricFormatting.placeholder` — because from the
/// UI's perspective they're the same claim: "no reading to show," not "the
/// reading is zero."
enum DashboardMetricCardFactory {

    static func cpu(_ stats: CPUStats?, palette: ThemePalette) -> DashboardMetricCard {
        DashboardMetricCard(
            title: MetricID.cpuTotalPercent.module.displayName,
            systemImage: MetricID.cpuTotalPercent.module.symbolName,
            tint: palette.metricColor(.cpuTotalPercent),
            headlineValue: MetricFormatting.percent(stats?.totalPercent),
            rows: stats.map {
                [
                    ("E-Cores", MetricFormatting.percent($0.ecorePercent)),
                    ("P-Cores", MetricFormatting.percent($0.pcorePercent)),
                    ("Load Avg", MetricFormatting.decimal($0.loadAverage1m)),
                    ("Processes", MetricFormatting.integer($0.processCount)),
                ]
            } ?? []
        )
    }

    static func gpu(_ stats: GPUStats?, palette: ThemePalette) -> DashboardMetricCard {
        DashboardMetricCard(
            title: MetricID.gpuUtilizationPercent.module.displayName,
            systemImage: MetricID.gpuUtilizationPercent.module.symbolName,
            tint: palette.metricColor(.gpuUtilizationPercent),
            headlineValue: MetricFormatting.percent(stats?.utilizationPercent),
            rows: stats.map {
                [
                    ("VRAM", MetricFormatting.bytes($0.vramUsedBytes)),
                    ("Frequency", MetricFormatting.megahertz($0.frequencyMHz)),
                    ("Power", MetricFormatting.watts($0.powerWatts)),
                ]
            } ?? []
        )
    }

    /// There is no public ANE utilization percentage (see `ANEStats`'s doc
    /// comment) — power draw above the idle floor is the industry-standard
    /// activity proxy, so the headline is watts, not a percent, matching the
    /// Mac app's own "ANE Power" label (`MetricID.anePowerWatts.shortLabel`).
    static func ane(_ stats: ANEStats?, palette: ThemePalette) -> DashboardMetricCard {
        DashboardMetricCard(
            title: "ANE",
            systemImage: MetricID.anePowerWatts.module.symbolName,
            // ANE has no dedicated theme color key; the Mac dropdown's
            // `ChartMetric.colorID` borrows GPU's for the same reason.
            tint: palette.metricColor(.gpuUtilizationPercent),
            headlineValue: MetricFormatting.watts(stats?.powerWatts),
            rows: stats.map {
                [("Active", MetricFormatting.boolean($0.isActive))]
            } ?? []
        )
    }

    static func memory(_ stats: MemoryStats?, palette: ThemePalette) -> DashboardMetricCard {
        let usedPercent = stats.flatMap { s -> Double? in
            guard s.totalBytes > 0 else { return nil }
            return Double(s.usedBytes) / Double(s.totalBytes) * 100
        }
        return DashboardMetricCard(
            title: MetricID.memoryUsedBytes.module.displayName,
            systemImage: MetricID.memoryUsedBytes.module.symbolName,
            tint: palette.metricColor(.memoryUsedBytes),
            headlineValue: MetricFormatting.percent(usedPercent),
            rows: stats.map {
                [
                    ("Used", MetricFormatting.bytes($0.usedBytes)),
                    ("Wired", MetricFormatting.bytes($0.wiredBytes)),
                    ("Compressed", MetricFormatting.bytes($0.compressedBytes)),
                    ("Pressure", MetricFormatting.memoryPressureLevel($0.pressureLevel)),
                ]
            } ?? []
        )
    }

    static func disk(_ stats: DiskStats?, palette: ThemePalette) -> DashboardMetricCard {
        let freePercent = stats.flatMap { s -> Double? in
            guard s.totalBytes > 0 else { return nil }
            return Double(s.freeBytes) / Double(s.totalBytes) * 100
        }
        return DashboardMetricCard(
            title: MetricID.diskReadBytesPerSec.module.displayName,
            systemImage: MetricID.diskReadBytesPerSec.module.symbolName,
            tint: palette.metricColor(.diskReadBytesPerSec),
            headlineValue: MetricFormatting.percent(freePercent, decimals: 1) + " free",
            rows: stats.map {
                [
                    ("Free", MetricFormatting.bytes($0.freeBytes)),
                    ("Total", MetricFormatting.bytes($0.totalBytes)),
                    ("Read", MetricFormatting.bytesPerSecond($0.readBytesPerSec)),
                    ("Write", MetricFormatting.bytesPerSecond($0.writeBytesPerSec)),
                ]
            } ?? []
        )
    }

    static func network(_ stats: NetworkStats?, palette: ThemePalette) -> DashboardMetricCard {
        DashboardMetricCard(
            title: MetricID.networkRxBytesPerSec.module.displayName,
            systemImage: MetricID.networkRxBytesPerSec.module.symbolName,
            tint: palette.metricColor(.networkRxBytesPerSec),
            headlineValue: MetricFormatting.bytesPerSecond(stats?.rxBytesPerSec),
            rows: stats.map {
                [
                    ("Upload", MetricFormatting.bytesPerSecond($0.txBytesPerSec)),
                    ("Network", $0.wifiSSID ?? $0.activeInterface ?? MetricFormatting.placeholder),
                    ("Signal", MetricFormatting.decibelMilliwatts($0.wifiRSSIdBm)),
                ]
            } ?? []
        )
    }

    static func thermal(_ stats: ThermalStats?, palette: ThemePalette) -> DashboardMetricCard {
        DashboardMetricCard(
            title: MetricID.thermalSocTempC.module.displayName,
            systemImage: MetricID.thermalSocTempC.module.symbolName,
            tint: palette.metricColor(.thermalSocTempC),
            headlineValue: MetricFormatting.celsius(stats?.socTemperatureCelsius),
            rows: stats.map {
                [
                    ("Pressure", MetricFormatting.pressureLevel($0.pressureLevel)),
                    ("Throttling", MetricFormatting.boolean($0.isThrottling)),
                    ("Fans", fanSummary($0.fanRPMs)),
                ]
            } ?? []
        )
    }

    /// "0, 0" for two silent fans, "—" when the Mac reports none at all
    /// (fanless models, or a snapshot predating the thermal collector).
    private static func fanSummary(_ rpms: [Double]) -> String {
        guard !rpms.isEmpty else { return MetricFormatting.placeholder }
        return rpms.map { String(Int($0.rounded())) }.joined(separator: ", ")
    }
}
