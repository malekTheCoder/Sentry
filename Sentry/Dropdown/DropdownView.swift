import SwiftUI
import SentryKit

/// Root of the menu-bar dropdown.
///
/// **The one job.** This popover opens under the cursor for a few seconds at a
/// time, so the top of it has to answer "is my Mac OK?" before the user has
/// finished focusing on it. That answer is a sentence — `SystemVitals.status`'s
/// headline — and it is the only thing on this surface allowed to be large.
/// Everything below it is the evidence for that sentence, in descending order:
/// four vitals rows, the keep-awake control, then the way out to the Dashboard.
///
/// **Restraint over chrome.** There are no cards here. The old layout wrapped
/// each region in a filled, stroked, rounded rectangle, which turned a 320pt
/// popover into six competing objects and spent six theme colors saying
/// nothing. Sections are separated by whitespace and a hairline `separator`;
/// hierarchy comes from the text ramp (`textPrimary` → `textSecondary` →
/// `textTertiary`) at two sizes; and `warning`/`danger` appear only next to a
/// reading that actually crossed a threshold. `accent` is reserved for
/// interactive state — the keep-awake switch, a hovered action.
///
/// **What the lighter pass established, and what changed.** Commit "Redesign
/// menu bar dropdown to a lighter headline-glance layout" cut the 7-card
/// scrolling module stack so a glance never requires scrolling; that intent is
/// kept — the resting height is still one screenful and the Dashboard is still
/// where history lives. What it lost was any way to see a module's detail
/// without leaving the popover, and `enabledModules` stopped being consulted at
/// all (turning a module off in Settings had no visible effect here). Both come
/// back as progressive disclosure rather than as permanently-open cards.
///
/// The Settings/Dashboard/Quit actions are injected closures rather than AppKit
/// calls so the AppDelegate stays the composition root and this view stays
/// previewable.
struct DropdownView: View {
    @ObservedObject private var viewModel: DropdownViewModel
    /// Observed here rather than only inside `SleepControlCard` so the card's
    /// position in the layout can't be the thing that decides whether state
    /// changes propagate; the service is owned by the AppDelegate composition
    /// root, same as the view model.
    @ObservedObject private var powerControl: PowerControlService
    /// Drives the header's agent-activity line — a live, user-visible signal
    /// that an MCP client is currently doing something to this Mac, which no
    /// headless competitor MCP server (thermo-control-mcp, mac-monitor-mcp)
    /// can show since none of them have a menu bar at all.
    @ObservedObject private var activityLog: MCPActivityLog
    /// Backs the agent-controls section (kill switch): the dropdown reads
    /// `mcpServerEnabled`/`agentGuardrails` live and writes the kill-switch
    /// flag straight back, the same "UI writes settings, `AppDelegate`'s
    /// settings sink enforces" one-way flow every settings pane uses —
    /// flipping the flag here is what triggers the assertion release and
    /// notice in `AppDelegate.applySettings`, not this view.
    @ObservedObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var systemColorScheme

    private let theme: Theme
    /// Only the quick switcher reads this — the dropdown renders `theme`, not
    /// a list. See `themeSwitcher`.
    private let customThemes: [Theme]
    private let enabledModules: Set<MetricModule>
    private let cardListMaxHeight: CGFloat
    /// Section visibility, user-configurable in Settings → Menu Bar.
    private let showsKeepAwake: Bool
    private let showsAgentActivitySetting: Bool
    private let onOpenSettings: () -> Void
    private let onOpenHistory: () -> Void
    private let onQuit: () -> Void
    /// Applies a theme picked from the dropdown's own quick switcher. nil
    /// hides the switcher (previews).
    private let onSelectTheme: ((String) -> Void)?

    /// Measured height of the content, so `cardListMaxHeight` can cap the
    /// popover without a `ScrollView` greedily claiming the full cap even when
    /// there are only four collapsed rows to show. See `body`.
    @State private var contentHeight: CGFloat = 0

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
        settingsStore: SettingsStore,
        theme: Theme = .defaultTheme,
        // The user's own themes, so the quick switcher below offers them
        // alongside the presets. Defaulting to empty rather than making the
        // parameter required keeps every preview and test call site unchanged
        // — and an empty list is a truthful state (a user who has never opened
        // the theme editor has no custom themes), not a placeholder.
        customThemes: [Theme] = [],
        enabledModules: Set<MetricModule> = Set(MetricModule.allCases),
        // Callers pass the actual anchor screen's height so this scales with
        // the display the status item lives on rather than a guess — a
        // fixed 420pt looked fine on paper but read as "half the cards are
        // missing and there's no way to see them" in practice (small popover
        // window against a much taller screen).
        cardListMaxHeight: CGFloat = 480,
        showsKeepAwake: Bool = true,
        showsAgentActivity: Bool = true,
        onOpenSettings: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onSelectTheme: ((String) -> Void)? = nil
    ) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._powerControl = ObservedObject(wrappedValue: powerControl)
        self._activityLog = ObservedObject(wrappedValue: activityLog)
        self._settingsStore = ObservedObject(wrappedValue: settingsStore)
        self.theme = theme
        self.customThemes = customThemes
        self.enabledModules = enabledModules
        self.cardListMaxHeight = cardListMaxHeight
        self.showsKeepAwake = showsKeepAwake
        self.showsAgentActivitySetting = showsAgentActivity
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.onQuit = onQuit
        self.onSelectTheme = onSelectTheme
    }

    private var palette: ThemePalette {
        ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    /// Text and rows both start here. The vitals and action rows draw a hover
    /// highlight that has to bleed slightly past their text, so they inset by
    /// `spacingBlock - spacingTight` and add `spacingTight` back inside — which
    /// puts every left edge on the same 1× `spacingBlock` line regardless.
    private var rowInset: CGFloat { palette.spacingBlock - palette.spacingTight }

    var body: some View {
        // A `ScrollView` sized to its own content rather than to its container.
        // Left to itself a vertical `ScrollView` is greedy in its scroll axis,
        // so `.frame(maxHeight:)` alone would pin the popover to the full
        // `cardListMaxHeight` even when four collapsed rows need 300pt. Measuring
        // the content and taking the min keeps the popover exactly as tall as it
        // needs to be, and only starts scrolling once expanding rows push it past
        // what the anchor screen can show — which is what `cardListMaxHeight` was
        // always for, and what it stopped doing when the scroll stack was cut.
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollIndicators(.automatic)
        .scrollDisabled(contentHeight <= cardListMaxHeight)
        .frame(width: 320)
        .frame(height: cappedHeight)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .themedBackdrop(palette)
        .environment(\.themePalette, palette)
    }

    /// `nil` until the content has been measured, which deliberately leaves the
    /// `ScrollView` unconstrained on the first layout pass: an unconstrained
    /// scroll view reports its content's ideal height, so the popover opens at
    /// the right size even if the measurement never arrives. Pinning it to a
    /// placeholder height instead would flash a 1pt popover on every open — and
    /// would fail *closed*, hiding the whole dropdown, if the preference ever
    /// stopped propagating.
    private var cappedHeight: CGFloat? {
        contentHeight > 0 ? min(contentHeight, cardListMaxHeight) : nil
    }

    private var content: some View {
        // `spacing: 0` throughout — every gap in this view is an explicit
        // padding off the spacing scale, so the rhythm is readable in one place
        // instead of being the sum of a stack spacing and four paddings.
        VStack(alignment: .leading, spacing: 0) {
            statusBlock
                .padding(.horizontal, palette.spacingBlock)
                .padding(.top, palette.spacingBlock)
                .padding(.bottom, palette.spacingRow)

            VitalsSection(
                vitals: vitals,
                isAwaitingFirstReading: viewModel.snapshot == nil,
                isStale: isStale,
                onOpenSettings: onOpenSettings
            )
            .padding(.horizontal, rowInset)
            .padding(.bottom, palette.spacingTight)

            hairline

            // The section is user-hideable (Settings → Menu Bar) — but never
            // while a session is actually running: an active keep-awake hold
            // is state the popover must always be able to show and end, so
            // the card overrides the setting for exactly as long as one is on.
            if showsKeepAwake || powerControl.state != .inactive {
                SleepControlCard(powerControl: powerControl)
                    .padding(.horizontal, rowInset)
                    .padding(.vertical, palette.spacingTight)

                hairline
            }

            // Kill switch (see AgentGuardrails): only meaningful while the
            // MCP server is enabled at all — a control that stops something
            // that can't be running would be noise. While *engaged* it shows
            // regardless, for the same reason the keep-awake card overrides
            // its own setting above: paused agent access is state this
            // surface must always be able to show and end.
            if settingsStore.settings.mcpServerEnabled
                || settingsStore.settings.agentGuardrails.killSwitchEngaged {
                agentControlSection
                    .padding(.horizontal, rowInset)
                    .padding(.vertical, palette.spacingTight)

                hairline
            }

            actionsRow
                .padding(.horizontal, rowInset)
                .padding(.vertical, palette.spacingTight)
        }
    }

    // MARK: - Agent controls (kill switch)

    /// Two states, one section: a prominent "paused" banner with the way
    /// out while the kill switch is engaged, and a one-row stop action while
    /// it isn't. Both write only to settings — enforcement and the
    /// assertion release live behind `AppDelegate`'s settings sink.
    @ViewBuilder
    private var agentControlSection: some View {
        if settingsStore.settings.agentGuardrails.killSwitchEngaged {
            HStack(spacing: palette.spacingTight) {
                // Only the icon + message are combined into one VoiceOver
                // element — not the whole row. The combine used to wrap the
                // `Button` too, which folds a `Button` into a non-interactive
                // combined element and makes it unreachable: VoiceOver users
                // lost the one control that un-pauses agent access, arguably
                // the most important control in the dropdown while this
                // banner is showing. Scoping `.combine` to just this HStack
                // keeps "Agent access paused / Every MCP tool call is being
                // declined." reading as one coherent announcement — which is
                // still the right behavior for those two lines — while
                // leaving the button as its own, independently focusable
                // element right after it.
                HStack(spacing: palette.spacingTight) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Agent access paused")
                            .font(palette.font(size: 12, weight: .semibold))
                            .foregroundStyle(palette.warning)
                        Text("Every MCP tool call is being declined.")
                            .font(palette.font(size: 10))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: palette.spacingTight)
                Button("Resume") {
                    setAgentAccessPaused(false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Resume agent access")
            }
            .padding(.horizontal, palette.spacingTight)
        } else {
            DropdownTextAction(
                title: String(localized: "Stop AI agents"),
                symbol: "bolt.slash",
                action: { setAgentAccessPaused(true) },
                isDestructive: true
            )
        }
    }

    private func setAgentAccessPaused(_ paused: Bool) {
        settingsStore.settings.agentGuardrails.killSwitchEngaged = paused
    }

    /// Full-bleed rather than inset: at 320pt an inset rule reads as a floating
    /// dash, while an edge-to-edge one reads as the section break it is.
    private var hairline: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    // MARK: - Status

    private var vitals: [Vital] {
        SystemVitals.vitals(for: viewModel.snapshot, enabledModules: enabledModules)
    }

    private var status: SystemStatus {
        SystemVitals.status(for: viewModel.snapshot, vitals: vitals, enabledModules: enabledModules)
    }

    /// The answer, then the machine it's about, then why.
    ///
    /// Machine name and uptime sit *above* the verdict as a small caption, not
    /// below it as a title: the user already knows whose Mac this is, and the
    /// most valuable line deserves the top of the reading order.
    private var statusBlock: some View {
        // Re-evaluated on a slow clock so "the collector stopped" is
        // detectable at all. Without it this view only redraws when a snapshot
        // arrives — precisely the event that stops happening in the failure
        // case it needs to report. 10s is far below the staleness threshold and
        // far above anything that would count as an idle wakeup problem, and
        // the timeline only exists while the popover is on screen.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            VStack(alignment: .leading, spacing: 3) {
                Text(captionLine(now: context.date))
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                headline

                if !status.reasons.isEmpty {
                    Text(status.reasons.prefix(2).joined(separator: " · "))
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsAgentActivity, let latest = activityLog.entries.first {
                    agentActivityLine(latest)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// The surface's only large type, and the only `.semibold` on it.
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingTight) {
            // No glyph in the healthy state: an icon that is always present
            // carries no information. It appears exactly when there is
            // something to flag, which is what makes it worth looking at — and
            // pairs the color so severity is never carried by hue alone.
            if let symbol = status.level.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 11))
            }
            Text(status.headline)
                .font(palette.font(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(headlineColor)
    }

    private var headlineColor: Color {
        switch status.level {
        case .normal: return palette.textPrimary
        case .warning: return palette.warning
        case .critical: return palette.danger
        }
    }

    private var machineName: String {
        // `Host.current().localizedName` is the user-facing "Malek's MacBook
        // Pro"; hostName is the network name and only a fallback.
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// "Malek's MacBook Pro · up 3d 4h" — plus "· updated 2m ago" once the
    /// readings are old enough to doubt.
    private func captionLine(now: Date) -> String {
        // Recomputed per body evaluation rather than on a timer of its own: a
        // minute-resolution readout doesn't justify a second wakeup source, and
        // the timeline above already ticks.
        var parts = [machineName, MetricFormatting.uptime(ProcessInfo.processInfo.systemUptime)]
        if let age = staleAge(now: now) {
            parts.append("updated \(Self.age(age)) ago")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Staleness

    /// Beyond this, a reading is old enough that it may no longer describe the
    /// machine. Deliberately above `StatsCoordinator`'s 60s ceiling: the fast
    /// tier legitimately stretches that far under adaptive throttling (battery
    /// × Low Power Mode), and a "stale" badge that fires on a Mac merely
    /// running on battery would be crying wolf.
    private static let staleAfter: TimeInterval = 75

    private func staleAge(now: Date) -> TimeInterval? {
        guard let timestamp = viewModel.snapshot?.timestamp else { return nil }
        let age = now.timeIntervalSince(timestamp)
        return age > Self.staleAfter ? age : nil
    }

    /// Dims the vitals rather than hiding them: old numbers are still the best
    /// information available, they just shouldn't be trusted as current.
    private var isStale: Bool {
        staleAge(now: Date()) != nil
    }

    /// "2m" / "1h 5m". Local to the dropdown rather than in `MetricFormatting`
    /// because this is an elapsed-time caption, not a metric value.
    private static func age(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    // MARK: - Agent activity

    /// Only write-tool calls that actually executed (`.allow`), and only for a
    /// short window after the fact — this is meant to read as "something just
    /// happened," not as a permanent "an agent is connected" badge (which
    /// `get_agent_activity`/the AI Access pane already cover for a full
    /// history). 20s comfortably covers one dropdown-open glance after a
    /// `keep_awake`/`create_alert_rule`/etc. call without lingering stale.
    private var showsAgentActivity: Bool {
        guard showsAgentActivitySetting else { return false }
        guard let latest = activityLog.entries.first,
              latest.tool.isWrite,
              latest.decision == .allow else { return false }
        return Date().timeIntervalSince(latest.timestamp) < 20
    }

    /// A line of text, not a tinted capsule. The old pill had a fill, a stroke
    /// and an accent tint for a transient informational note — three kinds of
    /// emphasis for something that disappears after 20 seconds.
    private func agentActivityLine(_ entry: MCPActivityLogEntry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt")
                .font(.system(size: 9))
            Text("\(entry.clientName) ran \(entry.tool.displayName)")
                .font(palette.font(size: 10))
                .lineLimit(1)
        }
        .foregroundStyle(palette.textTertiary)
        .accessibilityLabel("\(entry.clientName) just used \(entry.tool.displayName) on this Mac")
    }

    // MARK: - Actions

    /// Dashboard, Settings and Quit on one line. Settings and Quit stay
    /// icon-only and unlabelled because they're app utility rather than
    /// anything to do with the numbers above — but they stay *visible*, since
    /// left- and right-click both open this popover and there is no separate
    /// AppKit context menu to fall back on (see `StatusItemController`).
    private var actionsRow: some View {
        HStack(spacing: palette.spacingTight) {
            DropdownTextAction(
                title: "Open Dashboard",
                symbol: "chevron.right",
                action: onOpenHistory
            )
            Spacer(minLength: palette.spacingTight)
            if onSelectTheme != nil {
                themeSwitcher
            }
            DropdownIconAction(symbol: "gearshape", label: "Settings", action: onOpenSettings)
            DropdownIconAction(symbol: "power", label: "Quit Sentry", action: onQuit)
        }
    }

    /// Quick theme switcher: every theme one click away, without a trip
    /// through Settings. Same 28pt icon treatment as its neighbors so the
    /// action row reads as one control group.
    ///
    /// Custom themes come first and are separated by a divider: a user who
    /// authored a theme is switching *to* it far more often than to Monokai,
    /// and the fifteen presets below would otherwise bury it. When there are
    /// none, no divider and no empty section appears — the menu is exactly
    /// what it used to be.
    /// One row of the switcher menu. Extracted so the custom and built-in
    /// sections cannot drift — the checkmark rule in particular has to be
    /// identical or the active theme appears unselected in one of them.
    @ViewBuilder
    private func themeSwitcherItem(_ candidate: Theme) -> some View {
        Button {
            onSelectTheme?(candidate.id)
        } label: {
            if candidate.id == theme.id {
                Label(candidate.name, systemImage: "checkmark")
            } else {
                Text(candidate.name)
            }
        }
    }

    private var themeSwitcher: some View {
        Menu {
            ForEach(customThemes) { candidate in
                themeSwitcherItem(candidate)
            }
            if !customThemes.isEmpty {
                Divider()
            }
            ForEach(Theme.builtInPresets) { candidate in
                themeSwitcherItem(candidate)
            }
        } label: {
            Image(systemName: "paintbrush")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Theme")
        .accessibilityLabel("Theme, currently \(theme.name)")
    }
}

// MARK: - Content measurement

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Actions

/// A labelled action that behaves like a row, not a button: no fill, no
/// border, just a hover highlight and a trailing chevron. An outlined pill
/// would be the third distinct container shape on a surface that is trying
/// very hard to have none.
struct DropdownTextAction: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let symbol: String
    let action: () -> Void
    /// True for actions that revoke access rather than navigate — currently
    /// only "Stop AI agents".
    ///
    /// **Bug this fixes.** "Stop AI agents" and "Open Dashboard"
    /// (`actionsRow`) used to be two `DropdownTextAction`s with identical
    /// styling: same text weight, same `textPrimary`/`accent`-on-hover tint.
    /// One navigates, the other kills all agent access — reading them apart
    /// required actually parsing the words, every time. `isDestructive`
    /// tints the row `palette.danger` at rest (not just on hover, unlike the
    /// default treatment), the same token `ThemePane`'s contrast-audit flag
    /// and this file's own agent-paused banner already use for "something
    /// serious" — so this doesn't invent a new meaning for red, it reuses the
    /// one the app already has. `role: .destructive` on the underlying
    /// `Button` is free AX benefit on top (VoiceOver/Full Keyboard Access
    /// both understand the role), even though the row's own custom label
    /// means the system doesn't restyle it for us.
    var isDestructive: Bool = false

    @State private var isHovered = false

    private var tint: Color {
        isDestructive ? palette.danger : (isHovered ? palette.accent : palette.textPrimary)
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(palette.font(size: 11, weight: .medium))
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, palette.spacingTight)
            // 28pt: the accessibility floor for a hit target, and the same
            // height as a vitals row, so the two grids agree.
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .fill(palette.surface)
            }
        }
        .onHover { hovering in
            withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .accessibilityLabel(title)
    }
}

/// Icon-only sibling of `DropdownTextAction`, same 28pt hit target and same
/// hover treatment, so the action row reads as one control group.
struct DropdownIconAction: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let symbol: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? palette.textPrimary : palette.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .fill(palette.surface)
            }
        }
        .onHover { hovering in
            withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .help(label)
        .accessibilityLabel(label)
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
        // Throwaway file for the same reason as the defaults suite above —
        // a preview must never read or debounce-write the real settings.json.
        settingsStore: SettingsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("preview-dropdown-settings.json")
        ),
        theme: .defaultTheme,
        onOpenSettings: {},
        onOpenHistory: {},
        onQuit: {}
    )
}
