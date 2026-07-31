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
    /// Live agent/build-tool processes from `ProcessMonitor.agentProcesses`
    /// — the orchestration half of this card: who is running *right now*,
    /// how hard, next to what agents have *done* over the selected range.
    var agentProcesses: [ProcessStats] = []

    /// CPU at/above this reads as "working"; below it, "idle". Chosen well
    /// above libproc sampling noise but below any real compile/inference load.
    private static let workingCPUThreshold: Double = 5

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            if !agentProcesses.isEmpty {
                liveProcessList
            }
            content
        }
        .dashboardCard(palette)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI Agent Activity")
                .font(palette.font(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("In this range")
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textTertiary)
        }
    }

    /// Light accent tint, per the mock's `#c3caf7`-on-Slate readout color —
    /// a step lighter than the flat `palette.accent` dot/border/fill
    /// treatment used everywhere else, since here the color *is* the value's
    /// own text rather than a small signal next to it.
    private var statTint: Color { palette.accent.opacity(0.85) }

    @ViewBuilder
    private var content: some View {
        if let summary, summary.eventCount > 0 {
            HStack(alignment: .top, spacing: palette.spacing * 2.2) {
                stat(
                    value: "\(summary.eventCount)",
                    label: summary.eventCount == 1 ? "action" : "actions"
                )
                if let client = summary.mostActiveClient {
                    stat(value: client, label: "most active")
                }
                stat(
                    value: "\(summary.distinctToolCount)",
                    label: summary.distinctToolCount == 1 ? "tool used" : "tools used"
                )
            }
            .padding(.top, 2)
        } else if !agentProcesses.isEmpty {
            // Live processes are already listed above — a paragraph-length
            // empty state under a populated list read as the card
            // contradicting itself. One quiet line carries the range fact.
            Text("No MCP actions in this range.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        } else {
            Text("No AI agent activity in this range. Enable write tools in Settings → AI Access to let Claude Code, Cursor, or another MCP client act on this Mac.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One row per live process: name, pid, CPU, and a plain-word state.
    /// Grouping instances would hide exactly what an orchestration view
    /// exists to show — three parallel `claude` processes are three rows.
    private var liveProcessList: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            ForEach(agentProcesses) { process in
                HStack(spacing: palette.spacingTight) {
                    Circle()
                        .fill(process.cpuPercent >= Self.workingCPUThreshold
                            ? palette.success
                            : palette.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(process.name)
                        .font(palette.numericFont(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text("pid \(String(process.pid))")
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                    Spacer(minLength: palette.spacingTight)
                    Text(process.cpuPercent >= Self.workingCPUThreshold
                        ? "\(Int(process.cpuPercent.rounded()))% CPU"
                        : "idle")
                        .font(palette.numericFont(size: 11))
                        .foregroundStyle(palette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(process.name), process \(process.pid), " +
                    (process.cpuPercent >= Self.workingCPUThreshold
                        ? "working at \(Int(process.cpuPercent.rounded())) percent CPU"
                        : "idle")
                )
            }
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(statTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
        }
    }
}
