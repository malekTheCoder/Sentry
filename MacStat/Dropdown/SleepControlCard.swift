import SwiftUI
import MacStatKit

/// Plan §10.5: the sleep-prevention control that lives in the dropdown — a
/// toggle, a duration/trigger menu, an `AwakeMode` menu, and a live countdown
/// while an assertion is running.
///
/// **Layout.** Two states, one grid. Off, this is two rows: the switch, and a
/// summary of what flipping it will do ("Indefinitely · Keep display on")
/// which doubles as the disclosure for the pickers behind it. On, it is the
/// countdown plus the controls that move it. Nothing is boxed — the section is
/// bounded by the hairlines `DropdownView` draws above and below it, and the
/// labels/values sit on `DropdownGrid`, so the keep-awake rows and the vitals
/// rows above them share a left edge, a right edge and a row height.
///
/// The pickers used to be visible at all times, which put four rows and a
/// two-line explanation permanently under a switch that most users flip
/// without changing anything. They're one click away now instead, and the
/// collapsed summary states the current selection so the disclosure never
/// hides *what will happen* — only *how to change it*.
///
/// **Scope, and what's deliberately missing.** Plan §10.3 lists six trigger
/// kinds. Four are here (indefinite, fixed presets, battery threshold,
/// sustained-CPU threshold). Two are not:
///
/// - *Until a specific time* needs a `DatePicker`, and
/// - *While a specific app is running* needs a running-app browser.
///
/// Both would roughly double this card's height inside a 320pt popover whose
/// remaining space belongs to the vitals. They're deferred to the Settings
/// window, not dropped: `ReleaseCondition.whileAppRunning` already exists and
/// is fully handled by `PowerControlService`'s `NSWorkspace` termination
/// observer, and "until a time" is just a fixed duration computed from `Date`.
/// Neither needs service-layer work to land later — only UI.
///
/// **Why the card re-reads `powerControl.state` instead of mirroring it.**
/// The service is the single source of truth and can end an assertion without
/// this view asking: the expiry timer fires, a conditional trigger fires, or
/// wake/relaunch reconciliation decides the persisted assertion can't be
/// restored. Any locally cached "I turned it on" flag would keep claiming an
/// assertion that no longer exists, which is precisely the P5 lie this
/// codebase forbids. The only local state here is the user's *pending*
/// selection (what to start next) and the last start error.
struct SleepControlCard: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var powerControl: PowerControlService

    @State private var trigger: SleepTriggerOption = .indefinite
    @State private var mode: AwakeMode = .displayAndSystem
    @State private var batteryThreshold: Double = 20
    @State private var cpuThreshold: Double = 80
    /// Executable name for `.processRunning`. Defaults to the tool this
    /// feature was built for — an agent CLI chewing through a long task is
    /// the canonical "hold the Mac awake until it's done" workload.
    @State private var processName: String = "claude"

    /// Whether the trigger/mode pickers are disclosed. Local and not
    /// persisted: it's a "I'm about to change something" state, not a
    /// preference, and re-opening the popover should show the calm form.
    @State private var showsOptions = false

    /// Non-nil only when the most recent `startAssertion` attempt threw. Shown
    /// verbatim instead of a success state (P5) and cleared by the next
    /// successful start or by turning the toggle off.
    @State private var startError: String?

    /// `.cpuAbovePercent`'s sustained window. Fixed at the plan's five
    /// minutes rather than exposed: the point of the sustained clock is to
    /// stop a momentary dip from releasing a long build's assertion, and a
    /// user-tunable "how long" control invites values (0s, 1s) that quietly
    /// defeat it.
    private static let cpuSustainedWindow: TimeInterval = 5 * 60

    private var activeState: (mode: AwakeMode, expiresAt: Date?, reason: String)? {
        guard case .active(let mode, let expiresAt, let reason) = powerControl.state else { return nil }
        return (mode, expiresAt, reason)
    }

    private var isActive: Bool { activeState != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let activeState {
                activeDetail(for: activeState)
            } else {
                optionsDisclosure
                if showsOptions {
                    pickers
                }
            }
            if let startError {
                errorRow(startError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    /// The section's title row. `.medium` on `textPrimary` rather than a size
    /// jump: this is a heading among data rows, and the surface has exactly one
    /// slot for large type (the verdict line, above).
    private var header: some View {
        HStack(spacing: palette.spacingTight) {
            Text("Keep Awake")
                .font(palette.font(size: 11, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: palette.spacingTight)
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(palette.accent)
                .accessibilityLabel("Keep awake")
                .accessibilityValue(isActive ? "On, preventing sleep" : "Off, sleep behaves normally")
        }
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
    }

    /// Writes go straight to the service; reads come straight back from it.
    /// If `startAssertion` throws, `powerControl.state` stays `.inactive`, so
    /// the switch springs back on its own — the UI can't get stuck showing
    /// "on" for an assertion IOKit refused to create.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isActive },
            set: { wantsOn in wantsOn ? start() : stop() }
        )
    }

    // MARK: Inactive — configuration

    /// Collapsed, this row *is* the answer to "what happens if I flip that
    /// switch"; expanded, it becomes the group's label. Never both, because a
    /// summary sitting directly above the two controls it summarises is
    /// redundancy the eye still has to read.
    private var optionsDisclosure: some View {
        DropdownDisclosureRow(
            title: showsOptions ? "Options" : selectionSummary,
            isExpanded: showsOptions,
            accessibilityLabel: showsOptions
                ? "Hide keep awake options"
                : "Keep awake options, currently \(selectionSummary)"
        ) {
            withAnimation(ThemePalette.disclosureMotion(reduceMotion: reduceMotion)) {
                showsOptions.toggle()
            }
        }
    }

    private var selectionSummary: String {
        let triggerText = trigger.menuLabel(
            batteryThreshold: batteryThreshold,
            cpuThreshold: cpuThreshold,
            processName: processName
        )
        return "\(triggerText) · \(mode.shortLabel)"
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 0) {
            optionMenu(
                title: "For",
                selection: trigger.menuLabel(
                    batteryThreshold: batteryThreshold,
                    cpuThreshold: cpuThreshold,
                    processName: processName
                )
            ) {
                ForEach(SleepTriggerOption.allOptions) { option in
                    Button(option.pickerLabel) { trigger = option }
                }
            }
            thresholdStepper
            optionMenu(title: "Mode", selection: mode.shortLabel) {
                ForEach(AwakeMode.allCases, id: \.self) { candidate in
                    Button(candidate.longLabel) { mode = candidate }
                }
            }
            Text(mode.explanation)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, palette.spacingTight)
                .padding(.bottom, palette.spacingTight)
        }
        .transition(.opacity)
    }

    /// Only the two conditional triggers carry a tunable threshold, so the
    /// stepper appears with them rather than sitting permanently disabled.
    @ViewBuilder
    private var thresholdStepper: some View {
        switch trigger {
        case .batteryBelow:
            percentStepper("Battery floor", value: $batteryThreshold, range: 5...95)
        case .cpuAbove:
            percentStepper("CPU floor", value: $cpuThreshold, range: 10...100)
        case .processRunning:
            processNameRow
        case .indefinite, .fixed:
            EmptyView()
        }
    }

    /// Free-text executable name plus a menu of the agent/build tools this
    /// trigger exists for. The text field is the source of truth; the menu
    /// just types for you.
    private var processNameRow: some View {
        HStack(spacing: palette.spacingTight) {
            Text("Process")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacingTight)
            TextField("name", text: $processName)
                .textFieldStyle(.plain)
                .font(palette.numericFont(size: 11, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .accessibilityLabel("Process name")
            Menu {
                ForEach(["claude", "codex", "xcodebuild", "node", "python3"], id: \.self) { preset in
                    Button(preset) { processName = preset }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Common processes")
        }
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
    }

    private func percentStepper(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack(spacing: palette.spacingTight) {
                Text(label)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
                Spacer(minLength: palette.spacingTight)
                Text(MetricFormatting.percent(value.wrappedValue))
                    .font(palette.numericFont(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
            }
        }
        .controlSize(.mini)
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
        .accessibilityLabel("\(label) \(MetricFormatting.percent(value.wrappedValue))")
    }

    /// A `Menu` rather than a `Picker`: `Picker`'s macOS pop-up button draws
    /// its own bezel, which is the one piece of system chrome this surface has
    /// nowhere to put.
    ///
    /// **The label is a single `Text` on purpose — this is a bug fix.** The
    /// previous version handed `Menu` an `HStack { Text(title); Spacer();
    /// Text(selection); Image(chevron) }` as its label. AppKit's borderless
    /// pop-up cannot host an arbitrary view hierarchy: it flattened the label
    /// down to one glyph and one string, so both rows shipped rendering as a
    /// stray up/down chevron next to "For" — the *current selection was never
    /// drawn at all*, and the control looked broken because, functionally, it
    /// was: the only way to see what was selected was to open the menu. The
    /// title now lives outside the `Menu` where we control it, the menu's own
    /// label is nothing but the selection string, and the system indicator is
    /// left visible (rather than hidden and re-drawn by hand) so the affordance
    /// can't disappear again. It lands in the same chevron column the vitals
    /// rows reserve, so the row still lines up.
    private func optionMenu<Content: View>(
        title: String,
        selection: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: palette.spacingTight) {
            Text(title)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacingTight)
            Menu {
                content()
            } label: {
                Text(selection)
                    .font(palette.font(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(title), \(selection)")
        }
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
    }

    // MARK: Active — countdown

    @ViewBuilder
    private func activeDetail(for active: (mode: AwakeMode, expiresAt: Date?, reason: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let expiresAt = active.expiresAt {
                // `TimelineView` is scoped to this branch on purpose: an
                // indefinite or condition-released assertion has nothing that
                // changes once per second, and a 1 Hz redraw of the whole
                // dropdown for a static string is exactly the kind of idle
                // wakeup plan §3.2 tells us not to add.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdownRow(remaining: expiresAt.timeIntervalSince(context.date))
                }
            } else {
                valueRow(label: "Ends", value: "When you turn it off")
            }
            valueRow(label: "Mode", value: active.mode.shortLabel)
            // Extend/truncate only mean something with an `expiresAt` to
            // adjust — an indefinite hold or a conditional trigger (both
            // `expiresAt == nil`) has no clock for these buttons to move,
            // matching `PowerControlService.adjustAssertion(bySeconds:)`'s
            // own `.noAdjustableAssertion` guard.
            adjustRow(hasClock: active.expiresAt != nil)
            // `reason` is the string handed to IOKit at start time and is the
            // only record of a conditional trigger that survives an app
            // relaunch (the condition itself is private to the service), so
            // it — not a locally remembered selection — is what's shown.
            Text(active.reason)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, palette.spacingTight)
                .padding(.bottom, palette.spacingTight)
        }
    }

    /// Quick +/- adjustments to the running countdown, and the labelled way to
    /// end the session. `-15m` is allowed to end the assertion outright (via
    /// `adjustAssertion`'s own below-zero clamp) rather than being disabled
    /// once remaining time drops under 15 minutes — matching the "truncate"
    /// half of "extended or truncated or ended" the way a user would actually
    /// expect it to behave.
    ///
    /// "End Now" is a duplicate of the header switch, kept because a labelled
    /// verb next to the countdown is the discoverable version of "ended" once
    /// the timing controls are what the eye is on.
    private func adjustRow(hasClock: Bool) -> some View {
        HStack(spacing: 2) {
            if hasClock {
                adjustButton("−15m", delta: -15 * 60)
                adjustButton("+15m", delta: 15 * 60)
                adjustButton("+1h", delta: 60 * 60)
            }
            Spacer(minLength: palette.spacingTight)
            endNowButton
        }
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
    }

    private func adjustButton(_ title: String, delta: TimeInterval) -> some View {
        DropdownInlineButton(
            title: title,
            accessibilityLabel: delta < 0
                ? "Shorten by \(SleepCountdownFormatting.presetLabel(-delta))"
                : "Extend by \(SleepCountdownFormatting.presetLabel(delta))"
        ) {
            adjust(bySeconds: delta)
        }
    }

    /// Neutral at rest and `danger` only under the cursor: a permanently red
    /// word on an otherwise monochrome surface reads as an error message rather
    /// than a control, but the colour is genuinely useful at the moment the
    /// user is about to commit to ending the session.
    private var endNowButton: some View {
        DropdownInlineButton(
            title: "End Now",
            hoverTint: palette.danger,
            accessibilityLabel: "End keep awake now",
            action: stop
        )
    }

    private func countdownRow(remaining: TimeInterval) -> some View {
        valueRow(label: "Remaining", value: SleepCountdownFormatting.countdown(remaining))
    }

    /// The same label-left/value-right geometry as a vitals detail row, ending
    /// on the same right edge, so the keep-awake block and the vitals block
    /// read as one table rather than two.
    private func valueRow(label: String, value: String) -> some View {
        HStack(spacing: palette.spacingTight) {
            Text(label)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacingTight)
            Text(value)
                .font(palette.numericFont(size: 11, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.leading, palette.spacingTight)
        .padding(.trailing, DropdownGrid.valueTrailingInset(palette))
        .frame(height: DropdownGrid.detailRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: Error

    /// No tinted panel behind it. `danger` text plus a glyph is already two
    /// signals; a third (a filled rounded rectangle) is the "error card" idiom
    /// this surface spent the redesign removing.
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
            Text(message)
                .font(palette.font(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, palette.spacingTight)
        .padding(.bottom, palette.spacingTight)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func start() {
        // Arm-time validation for the process trigger: a hold on a process
        // that isn't running would release itself two ticks later, which
        // reads as "the switch is broken". Saying why beats a silent bounce.
        if case .processRunning = trigger {
            let name = processName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                startError = "Enter a process name first."
                return
            }
            processName = name
            guard PowerControlService.isProcessRunning(named: name) else {
                startError = "No process named “\(name)” is running right now."
                return
            }
        }
        let reason = trigger.assertionReason(
            batteryThreshold: batteryThreshold,
            cpuThreshold: cpuThreshold,
            processName: processName
        )
        do {
            if let condition = trigger.releaseCondition(
                batteryThreshold: batteryThreshold,
                cpuThreshold: cpuThreshold,
                cpuSustainedFor: Self.cpuSustainedWindow,
                processName: processName
            ) {
                try powerControl.startConditionalAssertion(mode: mode, condition: condition, reason: reason)
            } else {
                try powerControl.startAssertion(mode: mode, duration: trigger.duration, reason: reason)
            }
            startError = nil
            // The options were a means to starting this session; leaving them
            // open would push the countdown the user now cares about down the
            // popover behind controls that no longer apply.
            showsOptions = false
        } catch {
            // `PowerControlError.assertionFailed` is a `LocalizedError`; the
            // `localizedDescription` fallback covers anything else IOKit
            // surprises us with later.
            startError = error.localizedDescription
        }
    }

    private func stop() {
        powerControl.releaseAssertion()
        startError = nil
    }

    private func adjust(bySeconds delta: TimeInterval) {
        do {
            try powerControl.adjustAssertion(bySeconds: delta)
            startError = nil
        } catch {
            startError = error.localizedDescription
        }
    }
}

// MARK: - Shared row controls

/// A full-width row that expands something below it. Same 28pt height, same
/// hover highlight and same reserved chevron column as a vitals row, because
/// it is the same kind of thing: a line you click to see more.
struct DropdownDisclosureRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let isExpanded: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: palette.spacingTight) {
                Text(title)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: palette.spacingTight)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
                    .frame(width: DropdownGrid.chevronWidth, alignment: .trailing)
            }
            .padding(.horizontal, palette.spacingTight)
            .frame(height: DropdownGrid.rowHeight)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// A compact text button for controls that sit several-to-a-row (`+15m`,
/// `End Now`). No fill and no border at rest — the hover highlight is the
/// affordance, and it's the same highlight every other clickable line in the
/// dropdown uses.
struct DropdownInlineButton: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    /// Defaults to `textPrimary`; `End Now` overrides it to `danger`.
    var hoverTint: Color? = nil
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(palette.font(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? (hoverTint ?? palette.textPrimary) : palette.textSecondary)
                .padding(.horizontal, palette.spacingTight)
                .frame(height: DropdownGrid.rowHeight)
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
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Trigger options

/// The subset of plan §10.3's trigger list this card offers. Not
/// `CaseIterable`-synthesizable (two cases carry payloads), so the menu order
/// is spelled out in `allOptions` — which also lets the fixed presets appear
/// in ascending order between "Indefinite" and the conditional triggers.
///
/// Thresholds live on the *view*, not in these cases, so that flipping between
/// "battery below" and "CPU above" doesn't discard the number the user already
/// dialed in for the other one.
enum SleepTriggerOption: Hashable, Identifiable {
    case indefinite
    case fixed(TimeInterval)
    case batteryBelow
    case cpuAbove
    case processRunning

    static let allOptions: [SleepTriggerOption] = [
        .indefinite,
        .fixed(15 * 60),
        .fixed(30 * 60),
        .fixed(60 * 60),
        .fixed(2 * 60 * 60),
        .fixed(4 * 60 * 60),
        .fixed(8 * 60 * 60),
        .batteryBelow,
        .cpuAbove,
        .processRunning
    ]

    var id: String {
        switch self {
        case .indefinite: return "indefinite"
        case .fixed(let seconds): return "fixed-\(Int(seconds))"
        case .batteryBelow: return "battery"
        case .cpuAbove: return "cpu"
        case .processRunning: return "process"
        }
    }

    /// `nil` for everything that isn't a fixed window — both "indefinite" and
    /// the conditional triggers are open-ended as far as `PowerControlService`
    /// is concerned.
    var duration: TimeInterval? {
        if case .fixed(let seconds) = self { return seconds }
        return nil
    }

    func releaseCondition(
        batteryThreshold: Double,
        cpuThreshold: Double,
        cpuSustainedFor: TimeInterval,
        processName: String
    ) -> ReleaseCondition? {
        switch self {
        case .indefinite, .fixed:
            return nil
        case .batteryBelow:
            return .batteryBelowPercent(batteryThreshold)
        case .cpuAbove:
            return .cpuAbovePercent(cpuThreshold, for: cpuSustainedFor)
        case .processRunning:
            return .whileProcessRunning(name: processName)
        }
    }

    /// Menu-item text: self-contained, since a menu item has no adjacent
    /// threshold control to read the number off.
    var pickerLabel: String {
        switch self {
        case .indefinite: return "Indefinitely"
        case .fixed(let seconds): return SleepCountdownFormatting.presetLabel(seconds)
        case .batteryBelow: return "Until battery is low"
        case .cpuAbove: return "While CPU is busy"
        case .processRunning: return "While a process runs"
        }
    }

    /// Collapsed label for the closed menu, where the chosen threshold has to
    /// be visible without opening anything.
    func menuLabel(batteryThreshold: Double, cpuThreshold: Double, processName: String) -> String {
        switch self {
        case .indefinite, .fixed:
            return pickerLabel
        case .batteryBelow:
            return "Battery < \(MetricFormatting.percent(batteryThreshold))"
        case .cpuAbove:
            return "CPU > \(MetricFormatting.percent(cpuThreshold))"
        case .processRunning:
            return "While \(processName.isEmpty ? "process" : processName) runs"
        }
    }

    /// The `reason` string handed to IOKit — visible in `pmset -g assertions`
    /// and, more importantly, the only description of a conditional trigger
    /// that survives into `SleepAssertionState` for the active card to show.
    /// Prefixed with the app name because that's what shows up in system power
    /// diagnostics next to every other process's assertions.
    func assertionReason(batteryThreshold: Double, cpuThreshold: Double, processName: String) -> String {
        switch self {
        case .indefinite:
            return "Sentry — keep awake until turned off"
        case .fixed(let seconds):
            return "Sentry — keep awake for \(SleepCountdownFormatting.presetLabel(seconds))"
        case .batteryBelow:
            return "Sentry — keep awake until battery drops below \(MetricFormatting.percent(batteryThreshold))"
        case .cpuAbove:
            return "Sentry — keep awake while CPU stays above \(MetricFormatting.percent(cpuThreshold))"
        case .processRunning:
            return "Sentry — keep awake while \(processName) is running"
        }
    }
}

// MARK: - Formatting

/// Duration text specific to the sleep card. Separate from `MetricFormatting`
/// because these aren't metric values: a countdown is a clock readout (fixed
/// `mm:ss` field width so the digits don't jitter once a second under
/// `monospacedDigit`), whereas `MetricFormatter.uptime` deliberately drops the
/// seconds field entirely and would render every countdown under a minute as
/// a motionless "0m".
enum SleepCountdownFormatting {

    /// `1:04:09` / `4:09` / `0:09`. Clamped at zero: the assertion's release
    /// is driven by a `Timer` and an OS-level timeout, either of which can
    /// land a fraction of a second after the deadline, and a card flashing
    /// "-0:01" on the way out would be a bug the user sees.
    static func countdown(_ remaining: TimeInterval) -> String {
        guard remaining.isFinite else { return MetricFormatting.placeholder }
        // Rounding up means a fresh "15 min" assertion reads 15:00, not
        // 14:59, for the tick before the first second elapses.
        let total = Int(min(max(remaining.rounded(.up), 0), Double(Int32.max)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// `15 min` / `1 h` / `2 h 30 min`, for naming a preset that hasn't
    /// started yet (no seconds — a preset is a round number by construction).
    static func presetLabel(_ duration: TimeInterval) -> String {
        let total = Int(max(duration, 0).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        switch (hours, minutes) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return "\(h) h"
        case (let h, let m): return "\(h) h \(m) min"
        }
    }
}

// MARK: - AwakeMode labels

/// UI vocabulary for `AwakeMode`. Kept in the app target rather than on the
/// model in MacStatKit: the kit is shared with the iOS app and the MCP tool,
/// neither of which should inherit this card's phrasing.
extension AwakeMode {
    var shortLabel: String {
        switch self {
        case .displayAndSystem: return "Keep display on"
        case .systemOnly: return "System only"
        case .systemWhileOnAC: return "Only while plugged in"
        }
    }

    /// Menu-item text — long enough to distinguish the three without the
    /// explanation line, which the open menu doesn't show.
    var longLabel: String {
        switch self {
        case .displayAndSystem: return "Keep display on"
        case .systemOnly: return "System only (display may sleep)"
        case .systemWhileOnAC: return "Only while plugged in"
        }
    }

    var explanation: String {
        switch self {
        case .displayAndSystem:
            return "Screen and system stay awake. Best for presenting or watching."
        case .systemOnly:
            return "System stays awake; the display may sleep. Best for builds and downloads."
        case .systemWhileOnAC:
            return "Sleep is prevented only on AC power — on battery the Mac sleeps normally."
        }
    }
}

// MARK: - Preview

#Preview {
    SleepControlCard(powerControl: PowerControlService(defaults: UserDefaults(suiteName: "preview.sleepcard")!))
        .padding()
        .frame(width: 320)
        .environment(\.themePalette, ThemePalette(theme: .defaultTheme, scheme: .dark))
        .background(ThemePalette(theme: .defaultTheme, scheme: .dark).background)
}
