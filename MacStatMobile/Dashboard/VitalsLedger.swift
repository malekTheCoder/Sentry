import SwiftUI
import MacStatKit

// The redesign handoff's iOS Dashboard (direction 2b): a borderless vitals
// ledger — 20pt tabular numerals, hairline dividers, a context word or a
// 70pt sparkline on the right — plus the full-width Activity chart. This
// file replaces the old 7-card grid (`DashboardMetricCardFactory`): same
// data, same "nil renders — never a fabricated zero" discipline, different
// shape. Rows expand in place for the detail the cards used to carry, with
// a tertiary chevron for disclosure per the handoff's row idiom.

// MARK: - Sparkline

/// A bare Canvas polyline — no axes, no fill (the handoff reserves the
/// under-line fill for the CPU line on the big chart), tinted in the
/// metric's own color. Renders nothing (not a flat fake line) until there
/// are at least two real samples.
struct LedgerSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let span = max(high - low, .leastNonzeroMagnitude)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height - (size.height - 2) * CGFloat((value - low) / span) - 1
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Ledger row

/// One vitals row: label · context · 20pt numeral · sparkline, on a
/// hairline. The whole row is a ≥44pt tap target that expands the detail
/// rows in place.
struct VitalsLedgerRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let label: String
    /// Pre-formatted headline; "—" when the module is unavailable.
    let headline: String
    /// One quiet word of context ("no pressure", an SSID) — nil when the
    /// sparkline carries the story instead.
    var context: String? = nil
    var sparkline: [Double] = []
    var tint: Color = .clear
    /// Detail rows revealed by expanding; empty disables disclosure.
    var details: [(label: String, value: String)] = []

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: palette.spacingRow) {
                    Text(label)
                        .font(palette.font(size: 14))
                        .foregroundStyle(palette.textSecondary)
                    Spacer(minLength: palette.spacingRow)
                    if let context {
                        Text(context)
                            .font(palette.font(size: 11))
                            .foregroundStyle(palette.textTertiary)
                            .lineLimit(1)
                    }
                    Text(headline)
                        .font(palette.font(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(headline == MetricFormatting.placeholder ? palette.textTertiary : palette.textPrimary)
                    if !sparkline.isEmpty {
                        LedgerSparkline(values: sparkline, tint: tint)
                            .frame(width: 70, height: 22)
                    }
                    if !details.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(details.isEmpty)
            .accessibilityLabel("\(label), \(headline)")
            .accessibilityHint(details.isEmpty ? Text("") : Text(isExpanded ? "Collapses details" : "Expands details"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(details, id: \.label) { row in
                        DashboardDetailRow(label: row.label, value: row.value)
                    }
                }
                .padding(.bottom, palette.spacingRow)
            }
        }
        .ledgerDivider(palette)
    }
}

// MARK: - Ledger

/// The seven modules as ledger rows. A `nil` snapshot (nothing received,
/// or the Mac is unreachable and values have been degraded on purpose)
/// renders every headline as "—".
struct VitalsLedger: View {
    @Environment(\.themePalette) private var palette

    let snapshot: SystemSnapshot?
    let series: [MetricID: [Double]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VitalsLedgerRow(
                label: "CPU",
                headline: MetricFormatting.percent(snapshot?.cpu?.totalPercent),
                sparkline: series[.cpuTotalPercent] ?? [],
                tint: palette.metricColor(.cpuTotalPercent),
                details: snapshot?.cpu.map {
                    [
                        ("E-Cores", MetricFormatting.percent($0.ecorePercent)),
                        ("P-Cores", MetricFormatting.percent($0.pcorePercent)),
                        ("Load Avg", MetricFormatting.decimal($0.loadAverage1m)),
                        ("Processes", MetricFormatting.integer($0.processCount)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: "GPU",
                headline: MetricFormatting.percent(snapshot?.gpu?.utilizationPercent),
                sparkline: series[.gpuUtilizationPercent] ?? [],
                tint: palette.metricColor(.gpuUtilizationPercent),
                details: snapshot?.gpu.map {
                    [
                        ("VRAM", MetricFormatting.bytes($0.vramUsedBytes)),
                        ("Frequency", MetricFormatting.megahertz($0.frequencyMHz)),
                        ("Power", MetricFormatting.watts($0.powerWatts)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: "Memory",
                headline: MetricFormatting.percent(memoryUsedPercent),
                context: snapshot?.memory.map { MetricFormatting.bytes($0.usedBytes) },
                sparkline: series[.memoryUsedBytes] ?? [],
                tint: palette.metricColor(.memoryUsedBytes),
                details: snapshot?.memory.map {
                    [
                        ("Wired", MetricFormatting.bytes($0.wiredBytes)),
                        ("Compressed", MetricFormatting.bytes($0.compressedBytes)),
                        ("Pressure", MetricFormatting.memoryPressureLevel($0.pressureLevel)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: "Disk",
                headline: snapshot?.disk.map { MetricFormatting.bytes($0.freeBytes) } ?? MetricFormatting.placeholder,
                context: snapshot?.disk == nil ? nil : "free",
                details: snapshot?.disk.map {
                    [
                        ("Total", MetricFormatting.bytes($0.totalBytes)),
                        ("Read", MetricFormatting.bytesPerSecond($0.readBytesPerSec)),
                        ("Write", MetricFormatting.bytesPerSecond($0.writeBytesPerSec)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: "Network",
                headline: MetricFormatting.bytesPerSecond(snapshot?.network?.rxBytesPerSec),
                context: snapshot?.network.flatMap { $0.wifiSSID ?? $0.activeInterface },
                sparkline: series[.networkRxBytesPerSec] ?? [],
                tint: palette.metricColor(.networkRxBytesPerSec),
                details: snapshot?.network.map {
                    [
                        ("Upload", MetricFormatting.bytesPerSecond($0.txBytesPerSec)),
                        ("Signal", MetricFormatting.decibelMilliwatts($0.wifiRSSIdBm)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: "ANE",
                headline: MetricFormatting.watts(snapshot?.ane?.powerWatts),
                context: snapshot?.ane.flatMap { ane in
                    ane.isActive.map { $0 ? "active" : "idle" }
                },
                details: []
            )
            VitalsLedgerRow(
                label: "Thermals",
                headline: MetricFormatting.celsius(snapshot?.thermal?.socTemperatureCelsius),
                context: thermalContext,
                details: snapshot?.thermal.map {
                    [
                        ("Pressure", MetricFormatting.pressureLevel($0.pressureLevel)),
                        ("Throttling", MetricFormatting.boolean($0.isThrottling)),
                        ("Fans", Self.fanSummary($0.fanRPMs)),
                    ]
                } ?? []
            )
        }
    }

    private var memoryUsedPercent: Double? {
        guard let memory = snapshot?.memory, memory.totalBytes > 0 else { return nil }
        return Double(memory.usedBytes) / Double(memory.totalBytes) * 100
    }

    /// The handoff's context-word idiom: "no pressure" / "fans silent"
    /// instead of a second number — only claims the data supports.
    private var thermalContext: String? {
        guard let thermal = snapshot?.thermal else { return nil }
        if thermal.isThrottling { return "throttling" }
        switch thermal.pressureLevel {
        case .nominal:
            let fansParked = !thermal.fanRPMs.isEmpty && thermal.fanRPMs.allSatisfy { $0 < 1 }
            return fansParked ? "fans silent" : "no pressure"
        case .fair: return "some pressure"
        case .serious: return "serious pressure"
        case .critical: return "critical"
        }
    }

    private static func fanSummary(_ rpms: [Double]) -> String {
        guard !rpms.isEmpty else { return MetricFormatting.placeholder }
        return rpms.map { String(Int($0.rounded())) }.joined(separator: ", ")
    }
}

// MARK: - Activity chart

/// The full-width Activity plot: CPU / memory / GPU overlaid, each
/// normalized to its own observed peak (their units are incompatible — the
/// plot shows shapes; the sentence below carries the real CPU numbers).
/// Same honesty contract as the Mac's `ActivityOverlayChart`.
struct MobileActivityChart: View {
    @Environment(\.themePalette) private var palette

    let series: [MetricID: [Double]]

    private static let plotted: [(metric: MetricID, title: String)] = [
        (.cpuTotalPercent, "CPU"),
        (.memoryUsedBytes, "Memory"),
        (.gpuUtilizationPercent, "GPU"),
    ]

    private var drawable: [(metric: MetricID, title: String, values: [Double])] {
        Self.plotted.compactMap { entry in
            guard let values = series[entry.metric], values.count >= 2 else { return nil }
            return (entry.metric, entry.title, values)
        }
    }

    var body: some View {
        if drawable.isEmpty {
            Text("Activity appears after a few seconds of readings.")
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: palette.spacingTight) {
                HStack(spacing: palette.spacingRow) {
                    ForEach(drawable, id: \.metric) { entry in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(palette.metricColor(entry.metric))
                                .frame(width: 6, height: 6)
                            Text(entry.title)
                                .font(palette.font(size: 11))
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("last 60 s")
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
                Canvas { context, size in
                    for entry in drawable {
                        let peak = max(entry.values.max() ?? 1, .leastNonzeroMagnitude)
                        var path = Path()
                        for (index, value) in entry.values.enumerated() {
                            let x = size.width * CGFloat(index) / CGFloat(entry.values.count - 1)
                            let y = size.height - (size.height - 4) * CGFloat(value / peak) - 2
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        context.stroke(
                            path,
                            with: .color(palette.metricColor(entry.metric)),
                            style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                        )
                    }
                }
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                        .fill(palette.surface.opacity(0.6))
                )
                .accessibilityLabel("Activity chart, last 60 seconds")
                .accessibilityValue(cpuSentence ?? "relative activity shapes")
                if let sentence = cpuSentence {
                    Text(sentence)
                        .font(palette.font(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(palette.textTertiary)
                }
            }
        }
    }

    private var cpuSentence: String? {
        guard let cpu = series[.cpuTotalPercent], !cpu.isEmpty else { return nil }
        let avg = cpu.reduce(0, +) / Double(cpu.count)
        let peak = cpu.max() ?? 0
        return String(format: "avg CPU %.0f%% · peak %.0f%%", avg, peak)
    }
}
