import SwiftUI
import MacStatKit

/// Settings ▸ Fans — the fan-control plan's §7.2 control panel, as far as a
/// build with no write path can honestly take it.
///
/// **What is real on this screen.** Every RPM shown here is a live SMC
/// reading taken from the same `SMCFanBridge` → `ThermalCollector` path the
/// Dashboard's thermal card uses (the pane reads `FanControlService`, which
/// is fed the shared snapshot stream — it never opens a second SMC
/// connection, so the two surfaces cannot disagree). The fan count, the
/// per-fan RPM range, and the "no fans on this Mac" state all come from the
/// hardware. The mode picker, the curve, the ceiling, and the sensor
/// binding are all really persisted to `settings.json` and really survive
/// relaunch.
///
/// **What is not real, and is labelled as such in the UI rather than only
/// here.** Nothing on this screen can change a fan's speed. Writing an SMC
/// fan key requires root; Sentry runs unprivileged; the `SMAppService`
/// LaunchDaemon that would bridge that gap is not part of this build
/// (`docs/fan-control-spike.md`). So:
///   - The mode picker is `.disabled` for every case except Automatic, and
///     a persistent note under it — not a tooltip, not a footnote in grey
///     6pt — says why, in the words `FanWriteAvailability.explanation`
///     provides.
///   - "Return to Auto," the escape hatch plan §8 calls mandatory, is
///     **absent**, not present-and-greyed. A disabled escape hatch is worse
///     than none: it implies there is something to escape from. On this
///     build the fans have never left the firmware's control, so the
///     honest statement is the one the status section makes — "your Mac is
///     managing its own fans, and Sentry has never changed that."
///   - There is no curve editor (plan §7.3). Drag-a-point-on-a-graph is a
///     real piece of UI work, and building it to edit a curve that cannot
///     be applied would be building the most persuasive-looking dead
///     control in the app. The curve's numbers are shown read-only, with
///     the preset that produced them, so the persisted shape is at least
///     inspectable.
///
/// **The specific lie this pane was written to avoid.** The tempting
/// version of this screen shows a target-RPM slider pre-filled from the
/// SMC's `F{i}Tg` key — a real number, read from real hardware, which the
/// user drags and which then does nothing. `SMCReadOnlyFanControlBackend`'s
/// doc comment records the same refusal at the layer below. This codebase
/// has shipped that bug before in other clothes (see `SyncPane` and
/// `AlertsPane.historyIsAvailable` for the canonical writeups); it is not
/// shipping it again with a fan on it.
struct FanControlPane: View {

    @ObservedObject var store: SettingsStore
    @ObservedObject var service: FanControlService

    @Environment(\.themePalette) private var palette

    var body: some View {
        Form {
            statusSection
            fansSection
            modeSection
            if service.capability.canReadFanSpeeds {
                policySection
                sensorSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Status

    /// Opens with what is true about this Mac right now, before any
    /// control-shaped affordance appears. Ordered deliberately: hardware
    /// first (what have we got), then the write disclosure (what can we do
    /// with it), because a user who reads only the first two lines should
    /// still come away with the correct impression.
    private var statusSection: some View {
        Section {
            Label {
                Text(Self.capabilityHeadline(service.capability))
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: Self.capabilitySymbol(service.capability))
                    .foregroundStyle(Self.capabilityIsGood(service.capability)
                        ? palette.textSecondary
                        : palette.warning)
            }

            Text(Self.capabilityDetail(service.capability))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .unreadable = service.capability {
                // Offered only for the one capability state that can
                // plausibly change on a retry. A "Try again" button on a
                // fanless Air would be a button that can only ever fail.
                Button("Check again") { service.refreshCapability() }
            }

            Text(service.writeAvailability.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("This Mac")
        }
    }

    // MARK: - Live fans

    private var fansSection: some View {
        Section {
            if !service.hasSampled {
                // "Nothing sampled yet" is not "no fans" — see
                // `FanControlService.hasSampled`. A two-fan MacBook Pro
                // would otherwise be told it has none for the first few
                // seconds after launch.
                Text("Waiting for the first thermal sample.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if service.fans.isEmpty {
                Text(Self.capabilityDetail(service.capability))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(service.fans, id: \.descriptor.index) { fan in
                    LabeledContent(fan.displayName) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(fan.speed.displayText)
                                .font(palette.numericFont(size: 13))
                                .foregroundStyle(palette.textPrimary)
                            Text(Self.limitsLabel(fan.descriptor.limits))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Current Speed")
        } footer: {
            Text("Read live from this Mac's SMC — the same readings the Dashboard's thermal card shows. “Stopped” means exactly that: Apple Silicon parks its fans completely when the Mac is idle, so 0 rpm is a real measurement, not a missing one. A fan Sentry couldn't read says “Unavailable” instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: modeBinding) {
                ForEach(FanControlMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            // The whole picker, not the individual rows: SwiftUI's
            // `Picker` doesn't disable per-tag, and a picker that accepts a
            // selection then snaps back would be worse than one that plainly
            // won't move.
            .disabled(!canChangeMode)

            Text(store.settings.fanControl.defaultPolicy.mode.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !canChangeMode {
                Label {
                    Text(service.writeAvailability.shortLabel)
                        .font(.callout)
                } icon: {
                    Image(systemName: "lock")
                        .foregroundStyle(palette.warning)
                }
            }
        } header: {
            Text("Control Mode")
        } footer: {
            Text(canChangeMode
                ? "Applies to every fan unless one has its own setting below."
                : "The mode is locked to Automatic because Sentry has no way to change fan speed in this build. It's shown rather than hidden so you can see what the feature will offer — and so nothing here pretends to be in effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// True only if some backend could actually carry out a mode change.
    /// There is no such backend in this build — the property exists so the
    /// pane's disabled state is derived from the backend's own answer
    /// rather than from a hardcoded `false` that a future change could
    /// forget to update.
    private var canChangeMode: Bool {
        switch service.writeAvailability {
        case .needsPrivilegedHelper, .noFans, .hardwareUnreadable:
            return false
        }
    }

    /// Writes through to `SettingsStore` and mirrors into the service so
    /// the resolution preview below stays consistent with what's persisted.
    /// The binding is live even while the picker is disabled — persistence
    /// works; it's only the hardware write that doesn't.
    private var modeBinding: Binding<FanControlMode> {
        Binding(
            get: { store.settings.fanControl.defaultPolicy.mode },
            set: { newMode in
                store.settings.fanControl.defaultPolicy.mode = newMode
                service.settings = store.settings.fanControl
            }
        )
    }

    // MARK: - Policy (read-only presentation of persisted values)

    private var policySection: some View {
        Section {
            LabeledContent("Safety ceiling",
                           value: "\(Int(store.settings.fanControl.defaultPolicy.safetyCeilingCelsius.rounded())) °C")
            LabeledContent("Hysteresis",
                           value: "\(Int(store.settings.fanControl.defaultPolicy.hysteresisCelsius.rounded())) °C")

            ForEach(Array(store.settings.fanControl.defaultPolicy.curve.points.enumerated()), id: \.offset) { _, point in
                LabeledContent("\(Int(point.celsius.rounded())) °C",
                               value: "\(Int(point.rpm.rounded())) rpm")
            }
        } header: {
            Text("Curve")
        } footer: {
            Text("The curve, ceiling, and hysteresis Sentry has saved for you. They're shown read-only: a drag-to-edit curve editor for a curve that can't be applied would be the most convincing dead control in the app, so it isn't built yet. These values are real, they persist across relaunches, and they're what the feature will use once fan writes are possible.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sensors

    private var sensorSection: some View {
        Section {
            if service.availableSensors.isEmpty {
                Text("No per-sensor temperatures are available on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.availableSensors.prefix(8), id: \.name) { reading in
                    LabeledContent(reading.name, value: "\(Int(reading.celsius.rounded())) °C")
                }
            }
        } header: {
            Text("Sensors")
        } footer: {
            Text("The sensors a curve could bind to, named exactly as this Mac reports them. Apple Silicon exposes one sensor per cluster, not one per core, so these are clusters and packages — Sentry doesn't relabel them into something friendlier that it can't verify. With no sensor chosen, a curve would follow the hottest of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pure formatting (unit-tested without a view hierarchy)

    /// Headline for each capability state. Static and view-free, matching
    /// `SyncPane.intervalLabel`'s convention, so the wording is pinned down
    /// by tests rather than only by reading the file.
    static func capabilityHeadline(_ capability: FanControlCapability) -> String {
        switch capability {
        case .supported(let fans):
            return fans.count == 1 ? "1 fan detected" : "\(fans.count) fans detected"
        case .noFansPresent:
            return "This Mac has no fans"
        case .unreadable:
            return "Fan hardware couldn't be read"
        }
    }

    static func capabilityDetail(_ capability: FanControlCapability) -> String {
        switch capability {
        case .supported:
            return "Your Mac's firmware is managing these fans, and Sentry has never changed that."
        case .noFansPresent:
            return "Sentry asked the SMC how many fans this Mac has and it answered none — a fanless Mac cools passively, so there's nothing here to monitor or control."
        case .unreadable(let reason):
            return reason
        }
    }

    static func capabilitySymbol(_ capability: FanControlCapability) -> String {
        switch capability {
        case .supported: return "fan"
        case .noFansPresent: return "fan.slash"
        case .unreadable: return "questionmark.circle"
        }
    }

    static func capabilityIsGood(_ capability: FanControlCapability) -> Bool {
        if case .supported = capability { return true }
        return false
    }

    /// "1200–6241 rpm", or an explicit admission when the SMC's `F{i}Mn`/
    /// `F{i}Mx` keys couldn't be read. Never a fabricated range — a made-up
    /// ceiling is what a clamp would later be trusted against.
    static func limitsLabel(_ limits: FanHardwareLimits?) -> String {
        guard let limits, limits.isValid else { return "Range unknown" }
        return "\(Int(limits.minRPM.rounded()))–\(Int(limits.maxRPM.rounded())) rpm"
    }
}
