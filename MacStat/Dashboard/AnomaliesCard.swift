import SwiftUI
import MacStatKit

/// Plan §17 Phase 8: "anomaly detection / baselining." Honest empty state
/// when `anomalies.isEmpty` — "nothing unusual" is the expected common
/// case, not a placeholder waiting for data (plan §3.2 P5), so this reads
/// as a calm confirmation rather than a dead card.
struct AnomaliesCard: View {
    @Environment(\.themePalette) private var palette

    let anomalies: [MetricAnomaly]

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            content
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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: anomalies.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(anomalies.isEmpty ? palette.success : palette.warning)
            Text("Anomalies")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if anomalies.isEmpty {
            Text("Nothing unusual — every tracked metric is within its normal range for this Mac.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(anomalies) { anomaly in
                    HStack(alignment: .firstTextBaseline) {
                        Text(anomaly.displayName)
                            .font(palette.font(size: 12))
                            .foregroundStyle(palette.textPrimary)
                        Spacer(minLength: palette.spacing)
                        Text(deviationText(for: anomaly))
                            .font(palette.font(size: 12, weight: .medium))
                            .monospacedDigit()
                            // Higher-than-usual reads as the one worth a
                            // second look (warning); lower-than-usual is
                            // still flagged as notable but not alarming.
                            .foregroundStyle(anomaly.percentDeviation > 0 ? palette.warning : palette.success)
                    }
                }
                Text("Compared to this Mac's own trailing 14-day average — not a fixed threshold or another Mac's numbers.")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func deviationText(for anomaly: MetricAnomaly) -> String {
        let sign = anomaly.percentDeviation > 0 ? "+" : ""
        return "\(sign)\(Int(anomaly.percentDeviation.rounded()))% vs baseline"
    }
}
