import SwiftUI
import MacStatKit

/// Plan §17 Phase 8 stretch: "per-process CPU/GPU/network attribution" —
/// see `ProcessCollector`'s doc comment for why this ships CPU + memory
/// only. Live-only, Dashboard-only (not part of `SystemSnapshot`, not
/// synced, not queryable over MCP) — see `ProcessStats`'s doc comment for
/// why a ranked live list doesn't fit this app's history/sync model.
struct TopProcessesCard: View {
    @Environment(\.themePalette) private var palette

    let processes: [ProcessStats]

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            content
        }
    }

    private var header: some View {
        Text("Top Processes")
            .font(palette.font(size: 14, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
    }

    @ViewBuilder
    private var content: some View {
        if processes.isEmpty {
            Text("Gathering process data…")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(processes) { process in
                    HStack {
                        Text(process.name)
                            .font(palette.font(size: 12))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: palette.spacing)
                        Text(MetricFormatting.bytes(process.residentMemoryBytes))
                            .font(palette.font(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(palette.textTertiary)
                        Text(String(format: "%.0f%%", process.cpuPercent))
                            .font(palette.font(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}
