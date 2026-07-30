import SwiftUI
import MacStatKit

/// Plan §10.5: the sleep-prevention control that lives in the dropdown — a
/// toggle, a duration/trigger menu, an `AwakeMode` menu, and a live countdown
/// while an assertion is running.
///
/// **Scope, and what's deliberately missing.** Plan §10.3 lists six trigger
/// kinds. Four are here (indefinite, fixed presets, battery threshold,
/// sustained-CPU threshold). Two are not:
///
/// - *Until a specific time* needs a `DatePicker`, and
/// - *While a specific app is running* needs a running-app browser.
///
/// Both would roughly double this card's height inside a 320pt popover whose
/// remaining space belongs to the metric cards. They're deferred to the
/// Settings window, not dropped: `ReleaseCondition.whileAppRunning` already
/// exists and is fully handled by `PowerControlService`'s `NSWorkspace`
/// termination observer, and "until a time" is just a fixed duration computed
/// from `Date`. Neither needs service-layer work to land later — only UI.
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
    @ObservedObject var powerControl: PowerControlService

    @State private var trigger: SleepTriggerOption = .indefinite
    @State private var mode: AwakeMode = .displayAndSystem
    @State private var batteryThreshold: Double = 20
    @State private var cpuThreshold: Double = 80

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

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            if let activeState {
                activeDetail(for: activeState)
            } else {
                pickers
            }
            if let startError {
                errorRow(startError)
            }
        }
        .padding(palette.spacing * 1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(activeState == nil ? palette.separator : palette.accent.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: Header

    private var isActive: Bool { activeState != nil }

    private var header: some View {
        HStack(spacing: palette.spacing) {
            Image(systemName: isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(isActive ? palette.accent : palette.textSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep Awake")
                    .font(palette.font(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(isActive ? "Preventing sleep" : "Sleep behaves normally")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: palette.spacing)
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(palette.accent)
                .accessibilityLabel("Keep awake")
        }
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

    private var pickers: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            optionMenu(
                title: "For",
                selection: trigger.menuLabel(batteryThreshold: batteryThreshold, cpuThreshold: cpuThreshold)
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
                .font(palette.font(size: 9))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        case .indefinite, .fixed:
            EmptyView()
        }
    }

    private func percentStepper(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack {
                Text(label)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                Spacer(minLength: palette.spacing)
                Text(MetricFormatting.percent(value.wrappedValue))
                    .font(palette.font(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .controlSize(.mini)
        .accessibilityLabel("\(label) \(MetricFormatting.percent(value.wrappedValue))")
    }

    /// A `Menu` rather than a `Picker`: `Picker`'s macOS pop-up button draws
    /// its own system-chrome background, which reads as a foreign control
    /// against the themed cards. This keeps the label/value/chevron geometry
    /// of `MetricDetailRow`.
    private func optionMenu<Content: View>(
        title: String,
        selection: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: palette.spacing) {
                Text(title)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                Spacer(minLength: palette.spacing)
                Text(selection)
                    .font(palette.font(size: 10, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("\(title), \(selection)")
    }

    // MARK: Active — countdown

    @ViewBuilder
    private func activeDetail(for active: (mode: AwakeMode, expiresAt: Date?, reason: String)) -> some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
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
                MetricDetailRow(label: "Ends", value: "When you turn it off")
            }
            MetricDetailRow(label: "Mode", value: active.mode.shortLabel)
            // `reason` is the string handed to IOKit at start time and is the
            // only record of a conditional trigger that survives an app
            // relaunch (the condition itself is private to the service), so
            // it — not a locally remembered selection — is what's shown.
            Text(active.reason)
                .font(palette.font(size: 9))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countdownRow(remaining: TimeInterval) -> some View {
        HStack {
            Text("Remaining")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacing)
            Text(SleepCountdownFormatting.countdown(remaining))
                .font(palette.font(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remaining \(SleepCountdownFormatting.countdown(remaining))")
    }

    // MARK: Error

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(palette.font(size: 10))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(palette.danger.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
    }

    // MARK: Actions

    private func start() {
        let reason = trigger.assertionReason(batteryThreshold: batteryThreshold, cpuThreshold: cpuThreshold)
        do {
            if let condition = trigger.releaseCondition(
                batteryThreshold: batteryThreshold,
                cpuThreshold: cpuThreshold,
                cpuSustainedFor: Self.cpuSustainedWindow
            ) {
                try powerControl.startConditionalAssertion(mode: mode, condition: condition, reason: reason)
            } else {
                try powerControl.startAssertion(mode: mode, duration: trigger.duration, reason: reason)
            }
            startError = nil
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

    static let allOptions: [SleepTriggerOption] = [
        .indefinite,
        .fixed(15 * 60),
        .fixed(30 * 60),
        .fixed(60 * 60),
        .fixed(2 * 60 * 60),
        .fixed(4 * 60 * 60),
        .fixed(8 * 60 * 60),
        .batteryBelow,
        .cpuAbove
    ]

    var id: String {
        switch self {
        case .indefinite: return "indefinite"
        case .fixed(let seconds): return "fixed-\(Int(seconds))"
        case .batteryBelow: return "battery"
        case .cpuAbove: return "cpu"
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
        cpuSustainedFor: TimeInterval
    ) -> ReleaseCondition? {
        switch self {
        case .indefinite, .fixed:
            return nil
        case .batteryBelow:
            return .batteryBelowPercent(batteryThreshold)
        case .cpuAbove:
            return .cpuAbovePercent(cpuThreshold, for: cpuSustainedFor)
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
        }
    }

    /// Collapsed label for the closed menu, where the chosen threshold has to
    /// be visible without opening anything.
    func menuLabel(batteryThreshold: Double, cpuThreshold: Double) -> String {
        switch self {
        case .indefinite, .fixed:
            return pickerLabel
        case .batteryBelow:
            return "Battery < \(MetricFormatting.percent(batteryThreshold))"
        case .cpuAbove:
            return "CPU > \(MetricFormatting.percent(cpuThreshold))"
        }
    }

    /// The `reason` string handed to IOKit — visible in `pmset -g assertions`
    /// and, more importantly, the only description of a conditional trigger
    /// that survives into `SleepAssertionState` for the active card to show.
    /// Prefixed with the app name because that's what shows up in system power
    /// diagnostics next to every other process's assertions.
    func assertionReason(batteryThreshold: Double, cpuThreshold: Double) -> String {
        switch self {
        case .indefinite:
            return "MacStat — keep awake until turned off"
        case .fixed(let seconds):
            return "MacStat — keep awake for \(SleepCountdownFormatting.presetLabel(seconds))"
        case .batteryBelow:
            return "MacStat — keep awake until battery drops below \(MetricFormatting.percent(batteryThreshold))"
        case .cpuAbove:
            return "MacStat — keep awake while CPU stays above \(MetricFormatting.percent(cpuThreshold))"
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
        .background(ThemePalette(theme: .slate, scheme: .dark).background)
}
