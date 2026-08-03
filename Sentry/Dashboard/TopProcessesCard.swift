import AppKit
import SwiftUI
import SentryKit

/// Plan §17 Phase 8 stretch: "per-process CPU/GPU/network attribution" —
/// see `ProcessCollector`'s doc comment for why this ships CPU + memory
/// only. Live-only, Dashboard-only (not part of `SystemSnapshot`, not
/// synced, not queryable over MCP) — see `ProcessStats`'s doc comment for
/// why a ranked live list doesn't fit this app's history/sync model.
///
/// Rows follow the redesign handoff's list idiom: quiet surface fill on
/// hover, and the one inline action ("Quit", 11pt accent — the only accent
/// on this card) revealed only while hovering. Quitting asks politely:
/// `NSRunningApplication.terminate()` for apps, SIGTERM otherwise — never
/// SIGKILL, and any refusal is simply reflected by the process staying in
/// the list rather than a fake success.
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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(processes) { process in
                    ProcessRow(process: process)
                }
            }
        }
    }
}

private struct ProcessRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let process: ProcessStats

    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(process.name)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: palette.spacing)
            if isHovered {
                Button("Quit") { quit() }
                    .buttonStyle(.plain)
                    .font(palette.font(size: 11, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .accessibilityLabel("Quit \(process.name)")
            }
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
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: min(palette.cornerRadius, 8), style: .continuous)
                .fill(isHovered ? palette.surface : Color.clear)
        )
        // Negate the row's own inset so text stays aligned with the card's
        // other content; the fill still reads as a full-width row.
        .padding(.horizontal, -6)
        .onHover { hovering in
            withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
    }

    /// Ask first via `NSRunningApplication` (respects unsaved-changes
    /// prompts and app lifecycle); fall back to SIGTERM for processes that
    /// aren't apps. A failed signal (permissions, already gone) needs no
    /// error UI — the truth shows up in the list on the next sample.
    private func quit() {
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            app.terminate()
        } else {
            kill(process.pid, SIGTERM)
        }
    }
}
