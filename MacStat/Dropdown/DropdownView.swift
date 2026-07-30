import SwiftUI
import MacStatKit

/// Root of the menu-bar dropdown: header, a 2×2 headline-metric glance grid,
/// the keep-awake control, and a single "Open Dashboard" button.
///
/// This is the "lighter" Nocturne-redesign pass over the dropdown: the old
/// per-module scroll stack (7 cards with sparklines) and the battery hero
/// card are cut from *this view's body* on purpose, so a glance at the menu
/// bar doesn't require scrolling — but their types (`ModuleCardStack`,
/// `BatteryHeroCard`) are left intact since the Dashboard still uses them.
/// Depth now lives one click away, behind "Open Dashboard," rather than
/// spread across this popover.
///
/// The footer/dashboard actions are injected closures rather than AppKit
/// calls so the AppDelegate stays the composition root and this view stays
/// previewable.
struct DropdownView: View {
    @ObservedObject private var viewModel: DropdownViewModel
    /// Observed here rather than only inside `SleepControlCard` so the card's
    /// position in the layout can't be the thing that decides whether state
    /// changes propagate; the service is owned by the AppDelegate composition
    /// root, same as the view model.
    @ObservedObject private var powerControl: PowerControlService
    /// Drives the header's "Agent active" indicator (see
    /// `DropdownHeader.agentActivityPill`) — a live, user-visible signal
    /// that an MCP client is currently doing something to this Mac, which no
    /// headless competitor MCP server (thermo-control-mcp, mac-monitor-mcp)
    /// can show since none of them have a menu bar at all.
    @ObservedObject private var activityLog: MCPActivityLog
    @Environment(\.colorScheme) private var systemColorScheme

    private let theme: Theme
    private let enabledModules: Set<MetricModule>
    private let cardListMaxHeight: CGFloat
    private let onOpenSettings: () -> Void
    private let onOpenHistory: () -> Void
    private let onQuit: () -> Void

    /// `@MainActor` because `PowerControlService` is main-actor isolated and
    /// this init stores one. Costs callers nothing: every one (AppDelegate,
    /// `#Preview`) is already main-actor isolated, as any code building a
    /// SwiftUI view hierarchy must be.
    @MainActor
    init(
        viewModel: DropdownViewModel,
        // Second, next to the other injected object it belongs with.
        //
        // Required, not optional-with-a-local-fallback: a locally constructed
        // service would read and write the same persisted assertion record as
        // the app's real one under `UserDefaults.standard`, so two live
        // instances would each try to reconcile (and re-create) the other's
        // assertion on wake. The composition root owns exactly one.
        powerControl: PowerControlService,
        activityLog: MCPActivityLog,
        theme: Theme = .slate,
        enabledModules: Set<MetricModule> = Set(MetricModule.allCases),
        // Callers pass the actual anchor screen's height so this scales with
        // the display the status item lives on rather than a guess — a
        // fixed 420pt looked fine on paper but read as "half the cards are
        // missing and there's no way to see them" in practice (small popover
        // window against a much taller screen).
        cardListMaxHeight: CGFloat = 480,
        onOpenSettings: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._powerControl = ObservedObject(wrappedValue: powerControl)
        self._activityLog = ObservedObject(wrappedValue: activityLog)
        self.theme = theme
        self.enabledModules = enabledModules
        self.cardListMaxHeight = cardListMaxHeight
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.onQuit = onQuit
    }

    private var palette: ThemePalette {
        ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            DropdownHeader(
                thermal: viewModel.snapshot?.thermal,
                latestActivity: activityLog.entries.first,
                onOpenSettings: onOpenSettings,
                onQuit: onQuit
            )
            HeadlineMetricGrid(snapshot: viewModel.snapshot)
            // A control the user came to press, not something to cut for
            // lightness — the live countdown is worth keeping permanently
            // visible even in the lighter layout.
            SleepControlCard(powerControl: powerControl)
            openDashboardButton
        }
        .padding(palette.spacing * 1.5)
        .frame(width: 320)
        .background(palette.background)
        .environment(\.themePalette, palette)
    }

    /// The only way to reach depth (module detail, history, sparklines) from
    /// this popover now — everything the old scroll stack showed inline
    /// lives one click away in the Dashboard window instead. Outlined, not
    /// filled: this is a navigation action, not the primary control on the
    /// card (that's the keep-awake toggle above it).
    private var openDashboardButton: some View {
        Button(action: onOpenHistory) {
            Text("Open Dashboard")
                .font(palette.font(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textPrimary)
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.textSecondary.opacity(0.5), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .accessibilityLabel("Open Dashboard")
    }
}

// MARK: - Header

/// Plan §8.3 item 1. The sync-status dot is deliberately absent — CloudKit
/// sync doesn't exist yet, and a permanently gray dot would imply a state the
/// app can't actually report.
///
/// **Settings/Quit access.** The lighter redesign made "Open Dashboard" the
/// only way to reach *depth* (module detail, history) from this popover —
/// but Settings and Quit aren't depth, they're basic app utility that has to
/// stay reachable from *somewhere*, and left/right-click both open this same
/// popover (see `StatusItemController`'s doc comment — there's no separate
/// AppKit context menu). Two small icon-only buttons here are that path:
/// unobtrusive enough not to fight the header's actual content (machine name,
/// thermal/agent pills) for attention, but always present.
private struct DropdownHeader: View {
    @Environment(\.themePalette) private var palette

    let thermal: ThermalStats?
    /// Most recent MCP activity-log entry, if any — used to show a brief
    /// "agent active" pill right after a write tool executes. `nil` (no
    /// entries yet) and an old/read-only entry both render nothing; see
    /// `showsAgentActivity`.
    let latestActivity: MCPActivityLogEntry?
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    /// Recomputed per body evaluation (i.e. per snapshot) rather than on a
    /// timer of its own — a minute-resolution readout doesn't justify a
    /// second wakeup source.
    private var uptime: String {
        MetricFormatting.uptime(ProcessInfo.processInfo.systemUptime)
    }

    /// Only write-tool calls that actually executed (`.allow`), and only for
    /// a short window after the fact — this is meant to read as "something
    /// just happened," not as a permanent "an agent is connected" badge
    /// (which `get_agent_activity`/the AI Access pane already cover for a
    /// full history). 20s comfortably covers one dropdown-open glance after
    /// a `keep_awake`/`create_alert_rule`/etc. call without lingering stale.
    private var showsAgentActivity: Bool {
        guard let latestActivity, latestActivity.tool.isWrite, latestActivity.decision == .allow else { return false }
        return Date().timeIntervalSince(latestActivity.timestamp) < 20
    }

    private var machineName: String {
        // `Host.current().localizedName` is the user-facing "Malek's MacBook
        // Pro"; hostName is the network name and only a fallback.
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(machineName)
                    .font(palette.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(uptime)
                    .font(palette.font(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: palette.spacing)
            if showsAgentActivity, let latestActivity {
                agentActivityPill(latestActivity)
            }
            thermalPill
            headerIconButton(symbol: "gearshape", label: "Settings", action: onOpenSettings)
            headerIconButton(symbol: "power", label: "Quit MacStat", action: onQuit)
        }
        .padding(.horizontal, 2)
    }

    private func headerIconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func agentActivityPill(_ entry: MCPActivityLogEntry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9))
            Text(entry.clientName)
                .font(palette.font(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(palette.accent.opacity(0.15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(palette.accent.opacity(0.4), lineWidth: 1))
        .accessibilityLabel("\(entry.clientName) just used \(entry.tool.displayName) on this Mac")
    }

    @ViewBuilder
    private var thermalPill: some View {
        if let thermal {
            let color = pillColor(for: thermal.pressureLevel)
            HStack(spacing: 4) {
                Image(systemName: thermal.isThrottling ? "exclamationmark.triangle.fill" : "thermometer.medium")
                    .font(.system(size: 9))
                Text(thermal.pressureLevel.displayName)
                    .font(palette.font(size: 10, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
            .accessibilityLabel("Thermal pressure \(thermal.pressureLevel.displayName)")
        } else {
            Text("Thermal —")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
        }
    }

    private func pillColor(for level: ThermalStats.PressureLevel) -> Color {
        switch level {
        case .nominal: return palette.success
        case .fair: return palette.warning
        case .serious, .critical: return palette.danger
        }
    }
}

// MARK: - Preview

#Preview {
    DropdownView(
        viewModel: DropdownViewModel(),
        // Throwaway suite so the preview never reads or writes the real app's
        // persisted assertion record.
        powerControl: PowerControlService(defaults: UserDefaults(suiteName: "preview.dropdown")!),
        activityLog: MCPActivityLog(),
        theme: .slate,
        onOpenSettings: {},
        onOpenHistory: {},
        onQuit: {}
    )
}
