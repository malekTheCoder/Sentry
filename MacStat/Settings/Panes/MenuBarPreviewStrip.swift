import SwiftUI
import MacStatKit

/// A SwiftUI approximation of the rendered status item, for the §8.2 live
/// preview strip.
///
/// **Why an approximation and not the real renderer:** the AppKit
/// `StatusItemView` draws into an `NSStatusItem` and is fed by a live
/// `SystemSnapshot`. Neither is available in the settings window — there is no
/// snapshot stream here — so this draws the same *layout decisions* (order,
/// spacing, separators, display mode, color rule, label/unit) against fixed
/// sample values. It is honest about geometry, not about your actual numbers.
struct MenuBarPreviewStrip: View {

    let layout: MenuBarLayout
    let theme: Theme

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("— sample values, not live readings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.background.color(for: colorScheme))

                if layout.modules.isEmpty {
                    Text("No modules — add one below")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                } else {
                    barContents
                        .padding(.horizontal, 10)
                }
            }
            .frame(height: 34)
            .frame(maxWidth: previewMaxWidth, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.separator.color(for: colorScheme), lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Menu bar preview")
            .accessibilityValue(accessibilityDescription)
        }
    }

    /// `maxWidth` truncates the real bar item; mirror it so the preview shows
    /// the user what their limit actually costs them.
    private var previewMaxWidth: CGFloat? {
        layout.maxWidth.map { CGFloat($0) }
    }

    private var barContents: some View {
        HStack(spacing: CGFloat(layout.spacing)) {
            ForEach(Array(layout.modules.enumerated()), id: \.element.id) { index, module in
                if index > 0 {
                    separator
                }
                moduleView(module)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var separator: some View {
        switch layout.separatorStyle {
        case .none:
            EmptyView()
        case .space:
            // The bar's own `spacing` already sits on both sides of this, so a
            // fixed sliver is what "extra space" actually looks like.
            Color.clear.frame(width: CGFloat(layout.spacing))
        case .dot:
            Text("·")
                .font(font(size: theme.barFontSize))
                .foregroundStyle(theme.textTertiary.color(for: colorScheme))
        case .line:
            Rectangle()
                .fill(theme.separator.color(for: colorScheme))
                .frame(width: 1, height: theme.barFontSize + 4)
        }
    }

    @ViewBuilder
    private func moduleView(_ module: BarModule) -> some View {
        let tint = color(for: module)

        HStack(spacing: 3) {
            if module.showLabel {
                Text(module.metric.shortLabel)
                    .font(font(size: theme.barFontSize - 1))
                    .foregroundStyle(theme.textSecondary.color(for: colorScheme))
            }

            switch module.displayMode {
            case .iconOnly:
                icon(for: module, tint: tint)
            case .valueOnly:
                valueText(for: module, tint: tint)
            case .iconAndValue:
                icon(for: module, tint: tint)
                valueText(for: module, tint: tint)
            case .sparkline:
                sparkline(tint: tint)
            case .sparklineAndValue:
                sparkline(tint: tint)
                valueText(for: module, tint: tint)
            case .bar:
                fillBar(for: module, tint: tint)
            case .arc:
                arc(for: module, tint: tint)
            }
        }
        .opacity(module.visibilityRule == .always ? 1.0 : 0.55)
        .overlay(alignment: .topTrailing) {
            // Conditionally-visible modules aren't always on the real bar;
            // dimming alone would encode that in appearance only (§9.4).
            if module.visibilityRule != .always {
                Image(systemName: "eye.slash")
                    .font(.system(size: 6))
                    .foregroundStyle(theme.textTertiary.color(for: colorScheme))
                    .offset(x: 4, y: -6)
            }
        }
        // Deliberately *not* resolved: the preview shows every conditional
        // module dimmed rather than actually applying the rule. It has no
        // snapshot, so "on battery" and "keeping the Mac awake" are unknowable
        // here, and `.whenAboveThreshold` could only be evaluated against this
        // file's invented sample value — which would hide or show a module
        // based on a number the user never had. Naming the condition is the
        // honest version; guessing the answer is not.
        .help(visibilityNote(for: module) ?? "")
    }

    private func visibilityNote(for module: BarModule) -> String? {
        module.visibilityRule.previewSummary(unit: module.metric.unit)
    }

    // MARK: - Display-mode pieces

    private func icon(for module: BarModule, tint: Color) -> some View {
        Image(systemName: MenuBarPreviewStrip.symbolName(for: module.metric))
            .font(.system(size: theme.barFontSize))
            .foregroundStyle(tint)
    }

    private func valueText(for module: BarModule, tint: Color) -> some View {
        Text(sampleText(for: module))
            .font(font(size: theme.barFontSize, weight: weight))
            .monospacedDigit()
            .foregroundStyle(tint)
    }

    private func sparkline(tint: Color) -> some View {
        // A fixed, plausible-looking series: the point is the shape and the
        // width the mode occupies, not the data.
        let samples: [Double] = [0.30, 0.42, 0.28, 0.55, 0.48, 0.70, 0.61, 0.83, 0.66, 0.74]
        return GeometryReader { geo in
            Path { path in
                guard samples.count > 1 else { return }
                let stepX = geo.size.width / CGFloat(samples.count - 1)
                for (i, sample) in samples.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(i) * stepX,
                        y: geo.size.height * (1 - CGFloat(sample))
                    )
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: theme.chartLineWidth, lineJoin: .round))
        }
        .frame(width: theme.barGraphWidth, height: theme.barFontSize + 2)
    }

    private func fillBar(for module: BarModule, tint: Color) -> some View {
        let fraction = normalizedSample(for: module.metric)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(theme.separator.color(for: colorScheme))
            Capsule()
                .fill(tint)
                .frame(width: max(2, theme.barGraphWidth * CGFloat(fraction)))
        }
        .frame(width: theme.barGraphWidth, height: 6)
    }

    private func arc(for module: BarModule, tint: Color) -> some View {
        let fraction = normalizedSample(for: module.metric)
        return ZStack {
            Circle()
                .stroke(theme.separator.color(for: colorScheme), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: theme.barFontSize + 2, height: theme.barFontSize + 2)
    }

    // MARK: - Theme plumbing

    private var weight: Font.Weight {
        switch theme.barFontWeight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch theme.fontFamily {
        case .system: return .system(size: size, weight: weight)
        case .systemMono: return .system(size: size, weight: weight, design: .monospaced)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .custom(let name): return .custom(name, size: size)
        }
    }

    private func color(for module: BarModule) -> Color {
        switch module.colorRule {
        case .fixed(let hex):
            return ThemeColor(hex: hex).color(for: colorScheme)
        case .matchSystemAccent:
            return Color.accentColor
        case .themeMetricColor:
            return theme.metricColor(for: module.metric)?.color(for: colorScheme)
                ?? theme.accent.color(for: colorScheme)
        case .thresholdGradient(let low, let high):
            return MenuBarPreviewStrip.gradientColor(
                value: MenuBarPreviewStrip.sampleValue(for: module.metric),
                low: low,
                high: high,
                theme: theme,
                scheme: colorScheme
            )
        }
    }

    /// Green below `low`, amber between, red above `high`. `low > high` inverts
    /// the ramp, which is what "low free disk is bad" needs.
    private static func gradientColor(
        value: Double,
        low: Double,
        high: Double,
        theme: Theme,
        scheme: ColorScheme
    ) -> Color {
        let inverted = low > high
        let lo = min(low, high)
        let hi = max(low, high)
        let below = value <= lo
        let above = value >= hi

        if below { return (inverted ? theme.danger : theme.success).color(for: scheme) }
        if above { return (inverted ? theme.success : theme.danger).color(for: scheme) }
        return theme.warning.color(for: scheme)
    }

    // MARK: - Sample data

    private func sampleText(for module: BarModule) -> String {
        // Goes through the same formatter the real bar uses. Hand-rolling it
        // here is what made the preview lie: it showed "12450mV" where the
        // bar shows "12.45V", "5.0 GB" where the bar shows "5 GB/s", and
        // "31.2°C" where the bar shows "31°" — a preview whose whole job is
        // to look like the bar.
        MetricFormatter.compact(
            MenuBarPreviewStrip.sampleValue(for: module.metric),
            unit: module.metric.unit,
            includeUnit: module.showUnit
        )
    }

    /// Plausible fixed readings so the preview looks like a real bar. Battery
    /// 72% and CPU 14% are the plan's own example numbers.
    static func sampleValue(for metric: MetricID) -> Double {
        switch metric {
        case .batteryChargePercent: return 72
        case .batteryHealthPercent: return 91
        case .batteryChargingWatts: return 45.8
        case .batteryAdapterWatts: return 96
        case .batterySystemPowerWatts: return 18.4
        case .batteryTemperatureC: return 31.2
        case .batteryCycleCount: return 143
        case .cpuTotalPercent: return 14
        case .cpuUserPercent: return 9
        case .cpuSystemPercent: return 5
        case .cpuEcorePercent: return 22
        case .cpuPcorePercent: return 8
        case .cpuPowerWatts: return 3.4
        case .cpuFrequencyMHz: return 2840
        case .gpuUtilizationPercent: return 37
        case .gpuPowerWatts: return 5.1
        case .anePowerWatts: return 0.4
        case .memoryPressurePercent: return 43
        case .thermalSocTempC: return 48.6
        case .diskUsedPercent: return 68
        default:
            // Reasonable per-unit stand-ins for the long tail.
            switch metric.unit {
            case .percent: return 45
            case .watts: return 6.2
            case .celsius: return 42
            case .megahertz: return 1800
            case .bytes: return 12_884_901_888   // 12 GB
            case .bytesPerSecond: return 5_368_709_120
            case .minutes: return 96
            case .seconds: return 184_000
            case .millivolts: return 12_450
            case .milliamps: return 2_310
            case .decibelMilliwatts: return -52
            case .megabitsPerSecond: return 866
            case .boolean: return 1
            case .decimal: return 1.75
            case .thermalLevel: return 1
            case .count, .operationsPerSecond: return 412
            }
        }
    }

    /// 0...1 for the fill-bar and arc modes.
    private func normalizedSample(for metric: MetricID) -> Double {
        let value = MenuBarPreviewStrip.sampleValue(for: metric)
        switch metric.unit {
        case .percent: return min(max(value / 100, 0), 1)
        default: return 0.62   // no known scale — a fixed, obviously-illustrative fill
        }
    }

    private var accessibilityDescription: String {
        guard !layout.modules.isEmpty else { return "Empty. No modules configured." }
        return layout.modules
            .map { module in
                var spoken = "\(module.metric.shortLabel) \(sampleText(for: module))"
                // The dim + eye.slash cue is visual only; §9.4 wants the same
                // information to reach VoiceOver, and "only shown when
                // charging" is the whole reason the module looks faded.
                if let note = visibilityNote(for: module) {
                    spoken += ", \(note.lowercased())"
                }
                return spoken
            }
            .joined(separator: ", ")
    }

    static func symbolName(for metric: MetricID) -> String {
        metric.module.symbolName
    }
}
