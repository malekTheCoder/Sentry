import SwiftUI
import MacStatKit

/// AI-agent-integration pass (see MacStat-AI-Features-Research.md item #15,
/// "agent-flavored historical trend view"): summarizes MCP write-tool
/// activity — persisted by `HistoryStore.logAgentActivity` — over the same
/// `TimeRangePicker` window every other Dashboard chart tracks, so "how much
/// has an AI agent been doing to this Mac this week/month" is a real,
/// answerable question instead of only a live, session-scoped view (the
/// dropdown's transient pill, the AI Access pane's in-memory log).
///
/// Honest empty state, not a hidden card, when `summary.eventCount == 0` —
/// most users won't have an agent connected most of the time, and the panel
/// should say that plainly (plan §3.2 P5) rather than fabricate activity or
/// disappear in a way that reads as "this feature doesn't exist."
struct AgentActivityCard: View {
    @Environment(\.themePalette) private var palette

    let summary: AgentActivitySummary?

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
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundStyle(palette.accent)
            Text("AI Agent Activity")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let summary, summary.eventCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(summary.eventCount) action\(summary.eventCount == 1 ? "" : "s") in this range")
                    .font(palette.font(size: 20, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .monospacedDigit()
                if let client = summary.mostActiveClient {
                    Text("Most active: \(client) · \(summary.distinctToolCount) distinct tool\(summary.distinctToolCount == 1 ? "" : "s") used")
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
            }
        } else {
            Text("No AI agent activity in this range. Enable write tools in Settings → AI Access to let Claude Code, Cursor, or another MCP client act on this Mac.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
