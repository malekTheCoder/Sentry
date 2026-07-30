import SwiftUI
import MacStatKit

/// Plan §12.1's "per-metric history browser," deliberately scoped down to a
/// browsable list of the *latest snapshot's current values*, grouped by
/// module, rather than a full synthetic history per metric.
///
/// **Why the scope-down.** A real per-metric history browser implies a
/// CloudKit query over `SnapshotRecord`/rollup tables — the same job
/// `HistoryStore` does on the Mac side — and no such fetch API exists for
/// this transport (same gap `MockDataSource.dailyHealthHistory`'s doc
/// comment describes for `DailyHealth`, just for every `SnapshotRecord`
/// field instead of one). Fabricating a plausible-looking synthetic
/// *history* for all ~50 `MetricID` cases (`MacStatKit/Models/MetricID.swift`)
/// would be a large amount of invented, never-real numbers for a browser
/// whose actual job is letting someone find "what does GPU power currently
/// read" — disproportionate effort for what this build can honestly offer.
/// This instead reuses the one thing this app already has that's at least
/// *shaped* like real data: the latest `SystemSnapshot` from
/// `MockDataSource.snapshots()`, read out per-metric via
/// `SystemSnapshot.value(for:)` (`MacStatKit/Models/SystemSnapshot+MetricValue.swift`)
/// — the same accessor the Mac dropdown's chart uses
/// (`DropdownViewModel.value(of:in:)`), so a `nil` here means the same thing
/// it means there: "this Mac doesn't report this field," not "zero."
struct PerMetricHistoryBrowser: View {
    @Environment(\.themePalette) private var palette
    let snapshot: SystemSnapshot?

    @State private var selectedModule: MetricModule = .battery

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            Picker("Module", selection: $selectedModule) {
                ForEach(MetricModule.allCases, id: \.self) { module in
                    Text(module.displayName).tag(module)
                }
            }
            .pickerStyle(.segmented)

            if let snapshot {
                metricList(for: snapshot)
            } else {
                Text("No snapshot yet")
                    .font(.caption)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Per-Metric Browser")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("Current values only — no per-metric history query exists yet")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
        }
    }

    private func metricList(for snapshot: SystemSnapshot) -> some View {
        let metrics = MetricID.allCases.filter { $0.module == selectedModule }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element) { index, metric in
                HStack {
                    Text(metric.shortLabel)
                        .font(.callout)
                        .foregroundStyle(palette.textSecondary)
                    Spacer(minLength: palette.spacing)
                    Text(MetricFormatting.value(snapshot.value(for: metric), metric: metric))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                }
                .padding(.vertical, 6)
                if index < metrics.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
    }
}
