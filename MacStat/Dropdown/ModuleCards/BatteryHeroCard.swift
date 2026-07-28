import SwiftUI
import MacStatKit

/// Plan §8.3 item 2: big charge arc, live wattage, time remaining, health,
/// cycles, adapter, and the charging-diagnostics line.
///
/// Every field below `chargePercent` is Optional on `BatteryStats`; rows whose
/// value is missing render an em dash rather than a fabricated zero (P5).
struct BatteryHeroCard: View {
    @Environment(\.themePalette) private var palette

    let battery: BatteryStats?
    let powerSeries: MetricSeries?

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            if let battery {
                HStack(alignment: .center, spacing: palette.spacing * 2) {
                    chargeArc(for: battery)
                    summary(for: battery)
                }
                diagnostics(for: battery)
                if let powerSeries, !powerSeries.isEmpty {
                    SparklineChart(series: powerSeries, tint: arcColor(for: battery), height: 32)
                }
            } else {
                Text("Battery Unavailable")
                    .font(palette.font(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Text("This Mac reported no battery data.")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    // MARK: Arc

    private func chargeArc(for battery: BatteryStats) -> some View {
        let fraction = min(max(battery.chargePercent / 100, 0), 1)
        let tint = arcColor(for: battery)
        return ZStack {
            Circle()
                .stroke(palette.separator, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))  // 12 o'clock start
                .shadow(color: tint.opacity(palette.glow), radius: palette.glow * 6)
                .animation(.easeInOut(duration: 0.3), value: fraction)
            VStack(spacing: 0) {
                Text(MetricFormatting.percent(battery.chargePercent))
                    .font(palette.font(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                if battery.isCharging {
                    // Paired icon so charge state isn't color-only (plan §9.4).
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: 86, height: 86)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge \(MetricFormatting.percent(battery.chargePercent))")
    }

    private func arcColor(for battery: BatteryStats) -> Color {
        if battery.isCharging { return palette.success }
        if battery.chargePercent <= 10 { return palette.danger }
        if battery.chargePercent <= 20 { return palette.warning }
        return palette.metricColor(MetricID.batteryChargePercent)
    }

    // MARK: Summary

    private func summary(for battery: BatteryStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(wattageHeadline(for: battery))
                .font(palette.font(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
            Text(stateLabel(for: battery))
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)

            MetricDetailRow(label: timeLabel(for: battery), value: timeValue(for: battery))
            MetricDetailRow(label: "Health", value: MetricFormatting.percent(battery.healthPercent, decimals: 1))
            MetricDetailRow(label: "Cycles", value: MetricFormatting.integer(battery.cycleCount))
            MetricDetailRow(label: "Temp", value: MetricFormatting.celsius(battery.temperatureCelsius))
            MetricDetailRow(label: "Adapter", value: adapterDescription(for: battery))
        }
    }

    /// Charging shows what's going *in*; on battery it shows what's being
    /// drawn *out*. Both come from different fields, either of which can be nil.
    private func wattageHeadline(for battery: BatteryStats) -> String {
        let watts = battery.isCharging ? battery.chargingWatts : battery.systemPowerInWatts
        return MetricFormatting.watts(watts)
    }

    private func stateLabel(for battery: BatteryStats) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }

    private func timeLabel(for battery: BatteryStats) -> String {
        battery.isCharging ? "Time to full" : "Time remaining"
    }

    private func timeValue(for battery: BatteryStats) -> String {
        MetricFormatting.minutesRemaining(
            battery.isCharging ? battery.timeToFullMinutes : battery.timeToEmptyMinutes
        )
    }

    private func adapterDescription(for battery: BatteryStats) -> String {
        if let description = battery.adapterDescription, !description.isEmpty {
            if let rated = battery.adapterRatedWatts {
                return "\(description) · \(rated) W"
            }
            return description
        }
        if let rated = battery.adapterRatedWatts { return "\(rated) W" }
        return battery.isPluggedIn ? "Connected" : MetricFormatting.placeholder
    }

    // MARK: Diagnostics

    @ViewBuilder
    private func diagnostics(for battery: BatteryStats) -> some View {
        let text = diagnosticsText(for: battery)
        HStack(spacing: 5) {
            Image(systemName: diagnosticsSymbol(for: battery))
                .font(.system(size: 10))
            Text(text)
                .font(palette.font(size: 10))
                .monospacedDigit()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(diagnosticsColor(for: battery))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(diagnosticsColor(for: battery).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
    }

    /// The plan's example line is "Charging at 45.8 W — 20 V / 2.3 A via 100 W
    /// adapter"; each clause is dropped independently when its field is nil
    /// rather than substituting zeros.
    /// `BatteryStats.notChargingReasonText` already reads e.g. "Paused (code
    /// 4194305)" or "Paused — Optimized Battery Charging" — it's a full,
    /// human sentence, not a bare reason fragment, so this must not prepend
    /// its own "Paused —" on top (that produced "Paused — Paused (code …)").
    /// It can also legitimately read "Charging normally" when the reason
    /// code is present but zero, which is not a pause at all and must fall
    /// through to the ordinary charging/discharging text below.
    private func diagnosticsText(for battery: BatteryStats) -> String {
        if let reason = battery.notChargingReasonText, Self.isPauseReason(reason) {
            return reason
        }
        if battery.isThermallyLimited {
            return "Paused — battery temperature"
        }
        guard battery.isCharging else {
            guard let draw = battery.systemPowerInWatts else {
                return battery.isPluggedIn ? "Plugged in" : "Discharging"
            }
            return "Drawing \(MetricFormatting.watts(draw))"
        }

        var line = battery.chargingWatts.map { "Charging at \(MetricFormatting.watts($0))" }
            ?? "Charging"
        var clauses: [String] = []
        if battery.voltageMV != nil || battery.amperageMA != nil {
            clauses.append("\(MetricFormatting.volts(battery.voltageMV)) / \(MetricFormatting.amps(battery.amperageMA))")
        }
        if let rated = battery.adapterRatedWatts {
            clauses.append("via \(rated) W adapter")
        }
        if !clauses.isEmpty {
            line += " — " + clauses.joined(separator: " ")
        }
        return line
    }

    private func diagnosticsColor(for battery: BatteryStats) -> Color {
        if battery.notChargingReasonText.map(Self.isPauseReason) == true || battery.isThermallyLimited {
            return palette.warning
        }
        return battery.isCharging ? palette.success : palette.textSecondary
    }

    private func diagnosticsSymbol(for battery: BatteryStats) -> String {
        if battery.notChargingReasonText.map(Self.isPauseReason) == true || battery.isThermallyLimited {
            return "exclamationmark.triangle.fill"
        }
        return battery.isCharging ? "bolt.fill" : "battery.50"
    }

    private static func isPauseReason(_ text: String) -> Bool {
        !text.isEmpty && text != "Charging normally"
    }
}
