import SwiftUI
import SentryKit

/// Settings ▸ Fans — the fan-control plan's §7.2 control panel.
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
/// **The write controls are live only when a privileged helper is
/// installed, and the default state of every install is "not installed".**
/// Writing an SMC fan key needs root, which needs the `SMAppService`
/// LaunchDaemon this build now contains (`SentryFanDaemon`). Until the user
/// presses Install — a button that exists on exactly one screen, with the
/// consequences spelled out next to it — this pane behaves exactly as it
/// did in Phase 2: live RPM, every write control disabled, and
/// `FanWriteAvailability.explanation` saying why in the same words the
/// backend reported them.
///
/// **The escape hatch appears with the thing it escapes from.** "Return
/// every fan to Auto" is shown when — and only when — writes are possible.
/// Phase 2 deliberately omitted it rather than greying it out, on the
/// grounds that a disabled escape hatch implies there is something to
/// escape from; that reasoning holds in reverse now, so the button appears
/// alongside the controls that can take a fan out of firmware control.
///
/// **Still absent: the curve editor (plan §7.3).** Drag-a-point-on-a-graph
/// remains unbuilt, and the curve is still shown read-only. The reason has
/// changed from "it would edit something that can't be applied" to a
/// narrower one: nothing in this build *applies a curve continuously* (see
/// `FanControlService`'s note on why the control loop is not in this
/// change), so a curve editor would still be editing a shape that only
/// takes effect the moment a person presses a button. Fixed speed is the
/// mode that works end to end today, and it is the one this pane offers
/// controls for.
///
/// **The specific lie this pane was written to avoid, still avoided.** The
/// tempting version of this screen shows a target-RPM slider pre-filled
/// from the SMC's `F{i}Tg` key, which the user drags and which then does
/// nothing. The slider here is bound to the persisted policy, is disabled
/// unless a write could actually happen, and its Apply button reports what
/// the daemon did — including the clamp — rather than assuming success.
struct FanControlPane: View {

    @ObservedObject var store: SettingsStore
    @ObservedObject var service: FanControlService

    @Environment(\.themePalette) private var palette

    /// The outcome of the most recent explicit action, shown verbatim.
    /// Nil until the user does something — this pane never displays a
    /// result for an action nobody took.
    @State private var lastActionMessage: String?
    @State private var lastActionWasFailure = false

    var body: some View {
        Form {
            statusSection
            helperSection
            fansSection
            modeSection
            if service.capability.canReadFanSpeeds {
                if service.writeAvailability.canWrite {
                    manualControlSection
                }
                policySection
                sensorSection
            }
        }
        .formStyle(.grouped)
        // The helper can go from "waiting for approval" to "enabled"
        // entirely outside this app — the user approves it in System
        // Settings, and nothing notifies us. Re-reading on appearance is
        // the cheap, prompt-free way to not show a stale "go approve it"
        // message to someone who just did.
        .onAppear { service.refreshWriteAvailability() }
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

            // Shown here only when there is no Fan Helper section below to
            // carry it — i.e. on a fanless Mac or one whose fan keys
            // wouldn't read, where "why can't I write" is a statement about
            // the hardware and belongs next to the hardware. Printing it in
            // both places (which the first draft did) gave the same
            // paragraph twice in a row, which reads as a bug and trains the
            // eye to skip the second one.
            if !service.supportsPrivilegedHelper {
                Text(service.writeAvailability.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("This Mac")
        }
    }

    // MARK: - Privileged helper

    /// The one place in the app that can install a root LaunchDaemon.
    ///
    /// Ordered so the consequences come before the button, and worded so a
    /// user who reads only the footer still knows what they are agreeing
    /// to. Hidden entirely on hardware where it could do nothing —
    /// `supportsPrivilegedHelper` is false for a fanless Mac and for a Mac
    /// whose fan keys wouldn't read, and an install button whose best
    /// outcome is "a root process with nothing to do" is not an offer worth
    /// making.
    @ViewBuilder
    private var helperSection: some View {
        if service.supportsPrivilegedHelper {
            Section {
                Label {
                    Text(service.writeAvailability.shortLabel)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: service.writeAvailability.canWrite ? "checkmark.shield" : "lock")
                        .foregroundStyle(service.writeAvailability.canWrite
                            ? palette.textSecondary
                            : palette.warning)
                }

                Text(service.writeAvailability.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .requiresPro = service.writeAvailability {
                    // Locked: no Install button is ever constructed — a free
                    // copy must not be walked into registering a root daemon
                    // whose writes would then be refused. No Buy button
                    // either (checkout doesn't exist; see ProUpsellCard).
                    // The one affordance that must survive a lapse is
                    // removal, which reverts every held fan first.
                    Text("Purchasing isn't available yet — Sentry's license checkout hasn't opened. Checkout is coming in an update.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if service.helperAppearsInstalled {
                        Button("Remove fan helper") { removeHelper() }
                    }
                } else if service.writeAvailability.canWrite {
                    Button("Remove fan helper") { removeHelper() }
                } else {
                    Button("Install fan helper…") { installHelper() }
                }

                if let lastActionMessage {
                    Label {
                        Text(lastActionMessage)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: lastActionWasFailure ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(lastActionWasFailure ? palette.warning : palette.textSecondary)
                    }
                }
            } header: {
                Text("Fan Helper")
            } footer: {
                Text("Installing adds a small background service that runs as an administrator — that's the only way macOS allows anything to change fan speed. It accepts three commands and nothing else, it clamps every speed to the range your Mac's own SMC reports, and it hands the fans straight back to your Mac's firmware if Sentry quits, crashes, or stops checking in for fifteen seconds. macOS will list it under Login Items & Extensions, where you can switch it off at any time. Removing it here returns every fan to Auto first.\n\nOne caveat worth knowing before you install: if you later delete Sentry by dragging it to the Trash, macOS never tells the helper to unregister. It stops being able to start, and a copy that happens to be running returns the fans to Auto and exits by itself within a minute — but a leftover entry can remain in Login Items. Removing the helper here, before deleting the app, avoids that entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func installHelper() {
        do {
            try service.installPrivilegedHelper()
            lastActionWasFailure = false
            lastActionMessage = service.writeAvailability.canWrite
                ? "The fan helper is installed and Sentry can reach it."
                : "macOS accepted the helper but hasn't started it yet. Check Login Items & Extensions."
        } catch {
            // Printed, not swallowed. On a build signed with anything other
            // than a real Developer ID identity this is where the user
            // finds out — registration genuinely cannot succeed, and an
            // install button that failed silently would be worse than one
            // that isn't there.
            lastActionWasFailure = true
            lastActionMessage = String(localized: "macOS wouldn't install the fan helper: \(error.localizedDescription)")
        }
    }

    private func removeHelper() {
        do {
            try service.removePrivilegedHelper()
            lastActionWasFailure = false
            lastActionMessage = String(localized: "The fan helper is removed and every fan is back under your Mac's own control.")
        } catch {
            lastActionWasFailure = true
            lastActionMessage = String(localized: "macOS wouldn't remove the fan helper: \(error.localizedDescription)")
        }
    }

    // MARK: - Manual control (shown only when a write can actually happen)

    /// Fixed-speed control and the escape hatch. Present only when
    /// `writeAvailability.canWrite`, so this whole section is absent on
    /// every install that hasn't opted into the helper — which is the inert
    /// default.
    private var manualControlSection: some View {
        Section {
            ForEach(service.fans, id: \.descriptor.index) { fan in
                LabeledContent(fan.displayName) {
                    HStack(spacing: 8) {
                        Text(Self.targetLabel(store.settings.fanControl.policy(forFan: fan.descriptor.index)))
                            .font(palette.numericFont(size: 13))
                            .foregroundStyle(palette.textPrimary)
                        Button("Apply") { apply(toFan: fan.descriptor.index) }
                    }
                }
            }

            Button(role: .destructive) {
                returnEverythingToAuto()
            } label: {
                Text("Return every fan to Auto")
            }
        } header: {
            Text("Fixed Speed")
        } footer: {
            Text("Apply sends the fixed speed saved for that fan to the helper, which clamps it to the fan's own range and reports back what it actually set — including when that differs from what you asked for. Nothing here runs continuously: a fan holds the speed you applied until you change it, until you press Return to Auto, or until Sentry stops checking in, at which point your Mac's firmware takes over again on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apply(toFan index: Int) {
        do {
            try service.applyPolicy(forFan: index)
            lastActionWasFailure = false
            lastActionMessage = String(localized: "Fan \(String(index + 1)): the helper accepted the request.")
        } catch {
            lastActionWasFailure = true
            lastActionMessage = String(localized: "Fan \(String(index + 1)): \(error.localizedDescription)")
        }
    }

    private func returnEverythingToAuto() {
        let failures = service.revertAllToAuto()
        if failures.isEmpty {
            lastActionWasFailure = false
            lastActionMessage = String(localized: "Every fan is back under your Mac's own control.")
        } else {
            // Names the fans that failed rather than reporting a bare
            // "something went wrong" — this is the panic button, and a user
            // pressing it needs to know exactly which fan is still held.
            lastActionWasFailure = true
            lastActionMessage = failures
                .map { failure -> String in
                    let indexText = String(failure.fanIndex + 1)
                    return String(localized: "Fan \(indexText): \(failure.reason)")
                }
                .joined(separator: "\n")
        }
    }

    /// "3 200 rpm" or an explicit admission that no fixed speed has been
    /// chosen. Never "0 rpm" for an unset value — `manualTargetRPM` being
    /// `nil` is a different state from being zero and has been since Phase 2
    /// (`FanControlPolicy.manualTargetRPM`).
    static func targetLabel(_ policy: FanControlPolicy) -> String {
        guard let rpm = policy.manualTargetRPM, rpm.isFinite else {
            return String(localized: "No fixed speed set")
        }
        let rpmText = String(Int(rpm.rounded()))
        return String(localized: "\(rpmText) rpm")
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
            Text(modeFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Three honest states, because two different "locked" reasons need two
    /// different sentences: a hardware/helper limitation is "this Mac can't"
    /// while `.requiresPro` is "this copy isn't licensed" — telling a Pro
    /// prospect their Mac can't change fan speed would be flatly false.
    private var modeFooterText: String {
        if canChangeMode {
            return String(localized: "Applies to every fan unless one has its own setting below. Changing the mode saves your choice; it doesn't move a fan on its own — use Apply, below, for that.")
        }
        if case .requiresPro = service.writeAvailability {
            return String(localized: "The mode is locked to Automatic because fan control is part of Sentry Pro. It's shown rather than hidden so you can see what the feature offers — and so nothing here pretends to be in effect.")
        }
        return String(localized: "The mode is locked to Automatic because Sentry currently has no way to change fan speed on this Mac. It's shown rather than hidden so you can see what the feature offers — and so nothing here pretends to be in effect.")
    }

    /// True only if the service says a write could actually happen.
    ///
    /// Routed through `FanWriteAvailability.canWrite` rather than
    /// re-switching over the cases here: there is exactly one case that
    /// means yes and six that mean no, and a `switch` in a view is a
    /// `switch` that another case could be added to with the wrong default.
    /// The model answers; the view asks.
    private var canChangeMode: Bool {
        service.writeAvailability.canWrite
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

    // MARK: - Temperature rendering

    /// This pane's house style for a temperature: whole degrees, a space,
    /// then the unit — `"95 °C"` / `"203 °F"` — in whichever unit the user
    /// picked in Settings ▸ General ▸ Units.
    ///
    /// Everything stored behind these strings stays Celsius:
    /// `FanControlPolicy.safetyCeilingCelsius`, `FanCurvePoint.celsius` and
    /// `ThermalSensorReading.celsius` are compared against raw sensor
    /// readings by `FanControlService` and by the privileged daemon, on a
    /// path no UI is part of. Converting any of them would change what the
    /// fans do; converting only the strings changes what the user reads.
    private static func temperature(_ celsius: Double) -> String {
        TemperatureFormatter.string(celsius: celsius, style: .wholeSpaced)
    }

    /// Same style, but for a temperature *span* rather than a reading — see
    /// the hysteresis row, and `TemperatureUnit.delta(fromCelsius:)`.
    private static func temperatureDelta(_ celsius: Double) -> String {
        TemperatureFormatter.delta(celsius: celsius, style: .wholeSpaced)
    }

    // MARK: - Policy (read-only presentation of persisted values)

    private var policySection: some View {
        Section {
            LabeledContent("Safety ceiling",
                           value: Self.temperature(store.settings.fanControl.defaultPolicy.safetyCeilingCelsius))
            // Hysteresis is a *width*, not a reading — "the sensor must move
            // this far before the fan is allowed to change" — so it converts
            // as a delta. Rendering 3 °C of hysteresis through the absolute
            // conversion would print "37 °F", which reads as a safety
            // ceiling rather than a deadband and is wrong by 32 degrees.
            LabeledContent("Hysteresis",
                           value: Self.temperatureDelta(store.settings.fanControl.defaultPolicy.hysteresisCelsius))

            ForEach(Array(store.settings.fanControl.defaultPolicy.curve.points.enumerated()), id: \.offset) { _, point in
                LabeledContent(Self.temperature(point.celsius),
                               value: "\(Int(point.rpm.rounded())) rpm")
            }
        } header: {
            Text("Curve")
        } footer: {
            Text("The curve, ceiling, and hysteresis Sentry has saved for you. They're shown read-only because nothing in this version follows a curve continuously — a fan holds whatever fixed speed you applied until something changes it. Building a drag-to-edit editor for a shape that only takes effect the moment you press a button would make it look like the curve is running when it isn't. These values are real and persist across relaunches.")
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
                    LabeledContent(reading.name, value: Self.temperature(reading.celsius))
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
            let countText = String(fans.count)
            return fans.count == 1
                ? String(localized: "1 fan detected")
                : String(localized: "\(countText) fans detected")
        case .noFansPresent:
            return String(localized: "This Mac has no fans")
        case .unreadable:
            return String(localized: "Fan hardware couldn't be read")
        }
    }

    static func capabilityDetail(_ capability: FanControlCapability) -> String {
        switch capability {
        case .supported:
            // Deliberately says nothing about who is *controlling* the
            // fans. Through Phase 2 this sentence ended "…and Sentry has
            // never changed that", which was true of every build that could
            // not write. It stops being reliably true the moment the helper
            // is installed, and a claim that quietly becomes false is worse
            // than one that was never made — so the control claim now lives
            // in the Fan Helper section, where it is derived from the
            // backend's live answer rather than baked into a string.
            return String(localized: "Sentry can read these fans directly from this Mac's SMC, including their individual speed ranges.")
        case .noFansPresent:
            return String(localized: "Sentry asked the SMC how many fans this Mac has and it answered none — a fanless Mac cools passively, so there's nothing here to monitor or control.")
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
        guard let limits, limits.isValid else { return String(localized: "Range unknown") }
        let minText = String(Int(limits.minRPM.rounded()))
        let maxText = String(Int(limits.maxRPM.rounded()))
        return String(localized: "\(minText)–\(maxText) rpm")
    }
}
