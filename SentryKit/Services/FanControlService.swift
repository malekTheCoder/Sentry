import Combine
import Foundation

/// One fan's current speed, as something the UI can render without ever
/// having to guess.
///
/// **The whole reason this type isn't just `Double?`.** `0` and "unknown"
/// are both falsy-looking and both extremely common on Apple Silicon — the
/// spike measured `F0Ac`/`F0Tg` reading exactly `0.0` at idle, because the
/// fans really are stopped — so an optional would put "the fan is off" and
/// "we failed to read the fan" one careless `?? 0` apart. An enum makes
/// that mistake impossible to write by accident and forces every display
/// site to answer the question deliberately.
public enum FanSpeedReading: Equatable, Sendable {
    /// A successful read. `0` here means the fan is genuinely stopped.
    case rpm(Double)
    /// The fan exists (the SMC reported it) but this sample had no usable
    /// value for it.
    case unavailable

    /// "1 780 rpm", "Stopped", or "Unavailable" — never a number that
    /// wasn't read.
    public var displayText: String {
        switch self {
        case .rpm(let value) where value <= 0:
            return "Stopped"
        case .rpm(let value):
            return "\(Int(value.rounded())) rpm"
        case .unavailable:
            return "Unavailable"
        }
    }
}

/// One fan, resolved for display: what it's doing, what it can do, and what
/// its policy *would* ask for if anything could ask.
public struct FanState: Equatable, Sendable {
    public var descriptor: FanDescriptor
    public var speed: FanSpeedReading
    /// What `FanControlResolver` computes for this fan right now. Computed
    /// and shown, never applied — see `FanControlService`'s doc comment.
    public var resolution: FanTargetResolution

    public init(descriptor: FanDescriptor, speed: FanSpeedReading, resolution: FanTargetResolution) {
        self.descriptor = descriptor
        self.speed = speed
        self.resolution = resolution
    }

    /// Display ordinal — SMC fan 0 is "Fan 1" to a person.
    public var displayName: String { "Fan \(descriptor.index + 1)" }
}

/// Plan §4.1's fan control service.
///
/// **What this actually does: it reads, it computes, and — as of Phase 3 —
/// it may apply.** It reads real fan speeds through whichever
/// `FanControlBackend` it was handed. It computes what the user's persisted
/// policy would request, through the pure `FanControlResolver`. And when
/// asked to apply that, it forwards to the backend, which either writes
/// (via the root daemon, when the user has installed it) or throws a typed,
/// printable reason.
///
/// **The apply path's shape did not change when writes became possible, and
/// that was the point of building it in Phase 2.** `applyPolicy(forFan:)`
/// threw `writesUnavailable(.needsPrivilegedHelper)` then and can throw
/// `helperRefused(reason:)` now; the Settings pane calls the same method it
/// always called. There was never an untested gap between "the button is
/// greyed out" and "the write is impossible", and there is now no untested
/// gap between that and "the write happened."
///
/// **The apply path is still not automatic.** Nothing in this type applies
/// a policy on a timer, on a snapshot tick, or at launch. `ingest(_:)`
/// updates the *computed preview* — what the policy would ask for — and
/// stops there. Closing that loop (a control loop that pushes a curve's
/// output to the hardware every few seconds) is genuinely more dangerous
/// than a one-shot write and is deliberately not in this change: it needs
/// its own rate limiting, its own oscillation analysis, and its own answer
/// for what happens when three consecutive writes fail. Today a fan moves
/// when a person asks it to.
///
/// **What is still deliberately not built here.**
///  - No timer, no polling loop of its own. Snapshots arrive via
///    `ingest(_:)` from the one `StatsCoordinator` stream every other
///    consumer reads (plan §3.2 P3).
///  - No startup recovery that re-arms a previous session's manual mode.
///    `FanControlSettings.restoreAutoOnLaunch` defaults to `true` and plan
///    §8 says "if state is ambiguous, default to Auto" — and after a
///    relaunch the state *is* ambiguous, because the daemon may still be
///    holding fans this process never took. The honest recovery is the one
///    that happens on the other side of the boundary: the old process's
///    disconnect already reverted them.
///  - No menu bar / dropdown surface (plan §7.1). Now that the controls can
///    do something this is worth revisiting; it is not revisited here,
///    because a change that adds a root daemon should not also be the
///    change that adds a one-click fan override to the surface users click
///    most often by accident.
@MainActor
public final class FanControlService: ObservableObject {

    private let backend: FanControlBackend

    /// Probed once at construction rather than per sample. Fan *count* and
    /// hardware limits are properties of the machine, not of the moment —
    /// re-reading four SMC keys per fan on every tick would be pure churn,
    /// and `refreshCapability()` exists for the one case where the answer
    /// could plausibly change (a transient `.unreadable` the user wants to
    /// retry).
    @Published public private(set) var capability: FanControlCapability

    /// Per-fan live state, rebuilt on each `ingest`. Empty until the first
    /// snapshot arrives — and empty means "nothing sampled yet", which the
    /// UI says in those words rather than rendering zeroes.
    @Published public private(set) var fans: [FanState] = []

    /// The sensors the curve modes could bind to, from the most recent
    /// snapshot. Named exactly as `HIDSensorBridge` reported them (or its
    /// positional "Sensor 3" fallback) — this layer does not rename sensors
    /// into friendlier-sounding roles it cannot verify, per plan §9's
    /// "avoid promising per-core unless the mapping is truly per-core."
    @Published public private(set) var availableSensors: [ThermalSensorReading] = []

    /// The last thermal pressure level seen. Available on every Mac
    /// (`ProcessInfo.thermalState`) even where no temperature sensor is, so
    /// `.hybrid`'s pressure-driven override has an input regardless.
    @Published public private(set) var pressure: ThermalStats.PressureLevel = .nominal

    /// Whether any snapshot has been ingested. Distinguishes "no fans" from
    /// "no data yet"; without it the pane's empty state would libel a
    /// perfectly healthy two-fan MacBook for the first few seconds after
    /// launch.
    @Published public private(set) var hasSampled = false

    /// The policy block the user has configured. Pushed in by the
    /// composition root from `SettingsStore` (same one-way flow as
    /// `AlertEngine.updateRules`), not read from disk here — this type owns
    /// no persistence.
    @Published public var settings: FanControlSettings

    /// Whether this copy is entitled to `ProFeature.fanControl`. Pushed in
    /// by the composition root from `LicenseProEntitlementStore` on every
    /// settings tick (same one-way flow as `settings` above) — this type
    /// never queries entitlement itself, so tests drive the gate with a
    /// plain boolean. Defaults locked: a service nobody seeded must not
    /// offer writes.
    @Published public var isProUnlocked = false

    /// Hysteresis memory, per fan index. Kept here rather than in
    /// `FanControlResolver` so the resolver stays a pure function of its
    /// inputs (see its doc comment).
    private var memory: [Int: FanResolutionMemory] = [:]

    public init(backend: FanControlBackend, settings: FanControlSettings = FanControlSettings()) {
        self.backend = backend
        self.settings = settings
        self.capability = backend.capability()
    }

    /// The backend's answer about writes, filtered through the Pro gate.
    /// The Settings pane renders `writeAvailability.explanation` verbatim
    /// next to every disabled control.
    ///
    /// Hardware facts pass through untouched — a fanless Mac has nothing
    /// to sell — but every helper-flavored state collapses to
    /// `.requiresPro` until this copy is entitled: the pane must not walk
    /// a free user through installing a root helper whose writes would
    /// then be refused. The backend itself stays entitlement-ignorant on
    /// purpose, so the revert paths (which consult the backend's own
    /// availability) keep working after a license lapses.
    public var writeAvailability: FanWriteAvailability {
        let real = backend.writeAvailability
        guard !isProUnlocked else { return real }
        switch real {
        case .noFans, .hardwareUnreadable:
            return real
        case .available, .needsPrivilegedHelper, .helperAwaitingApproval,
             .helperUnreachable, .requiresPro:
            return .requiresPro
        }
    }

    /// Whether the privileged helper is actually registered, judged from
    /// the backend's own un-gated availability. Exists for one consumer:
    /// the pane's locked state must keep "Remove fan helper" reachable when
    /// a license lapses with the helper installed — removal reverts every
    /// held fan first, and an escape hatch that disappears behind a paywall
    /// would be the worst possible lapse behavior.
    public var helperAppearsInstalled: Bool {
        switch backend.writeAvailability {
        case .available, .helperAwaitingApproval, .helperUnreachable:
            return true
        case .needsPrivilegedHelper, .noFans, .hardwareUnreadable, .requiresPro:
            return false
        }
    }

    public var backendIdentifier: String { backend.identifier }

    /// Whether this backend has a privileged helper worth offering to
    /// install. Forwarded so the pane never has to know which concrete
    /// backend it got — see `FanControlBackend`'s note on why this is on
    /// the protocol rather than reached by downcast.
    public var supportsPrivilegedHelper: Bool { backend.supportsPrivilegedHelper }

    /// Installs the privileged helper. **Called only from an explicit user
    /// action** — there is no path from launch, from `ingest`, or from
    /// `applyPolicy` to here, and adding one would mean an app that
    /// registers a root LaunchDaemon as a side effect of something else.
    /// Pro-gated (defense in depth with the pane's locked UI): a free copy
    /// must not install a root daemon it could never use.
    public func installPrivilegedHelper() throws {
        guard isProUnlocked else {
            throw FanControlWriteError.writesUnavailable(.requiresPro)
        }
        try backend.installPrivilegedHelper()
    }

    /// Removes the privileged helper. The backend hands every held fan back
    /// to the firmware before unregistering; see
    /// `PrivilegedFanControlBackend.removePrivilegedHelper`. Deliberately
    /// NOT Pro-gated — removal must survive a lapsed license.
    public func removePrivilegedHelper() throws {
        try backend.removePrivilegedHelper()
    }

    /// Plan §8's mandatory escape hatch, across every fan at once.
    /// Deliberately NOT Pro-gated — handing fans back to the firmware must
    /// survive a lapsed license (the backend's own availability, not the
    /// gated one, decides whether each revert can happen).
    ///
    /// Collects failures rather than throwing on the first one. "Return
    /// everything to Auto" that gave up halfway because fan 1 errored,
    /// leaving fan 2 held, would be the single worst behavior this button
    /// could have: the user pressed the panic control and it half-worked
    /// without saying which half.
    ///
    /// - Returns: the fans that could *not* be reverted, with the reason
    ///   each gave, for the pane to display. Empty means everything is back
    ///   under firmware control.
    @discardableResult
    public func revertAllToAuto() -> [(fanIndex: Int, reason: String)] {
        var failures: [(fanIndex: Int, reason: String)] = []
        for descriptor in capability.fans {
            do {
                try backend.revertToAuto(fan: descriptor.index)
            } catch {
                failures.append((descriptor.index, error.localizedDescription))
            }
        }
        return failures
    }

    /// Re-probes the hardware. Worth offering only for the `.unreadable`
    /// case — a fanless Mac will not grow fans, so the UI exposes this as a
    /// "Try again" affordance on that state alone.
    public func refreshCapability() {
        capability = backend.capability()
    }

    /// Re-reads the backend's write availability and republishes, so the
    /// pane redraws after the user approves the helper in System Settings —
    /// the one state change that happens with this app in the background
    /// and announces itself to nobody.
    ///
    /// `objectWillChange.send()` rather than a `@Published` mirror of
    /// `writeAvailability`: the value is derived from the backend on every
    /// read (`writeAvailability` above forwards), so a stored copy would be
    /// a second source of truth that could go stale in exactly the case
    /// this method exists for.
    public func refreshWriteAvailability() {
        backend.refreshWriteAvailability()
        objectWillChange.send()
    }

    // MARK: - Ingest

    /// Folds one sample into the published state. Called from the app's
    /// single snapshot loop.
    ///
    /// Fan speeds come from `thermal.fanRPMs` (the same array
    /// `ThermalCollector` already fills from `SMCFanBridge`) rather than
    /// from a second `backend.readActualRPMs()` call, so the Settings pane
    /// and the Dashboard's thermal card can never disagree about what the
    /// fans are doing — two independent SMC reads a few milliseconds apart
    /// would occasionally differ, and a user seeing two numbers for one fan
    /// has been told a lie by at least one of them.
    public func ingest(_ thermal: ThermalStats) {
        hasSampled = true
        pressure = thermal.pressureLevel
        availableSensors = thermal.perSensorCelsius
        rebuildFanStates(rpms: thermal.fanRPMs, socCelsius: thermal.socTemperatureCelsius)
    }

    private func rebuildFanStates(rpms: [Double], socCelsius: Double?) {
        let descriptors = capability.fans
        fans = descriptors.map { descriptor in
            let speed: FanSpeedReading = descriptor.index < rpms.count
                ? .rpm(rpms[descriptor.index])
                : .unavailable

            let policy = settings.policy(forFan: descriptor.index)
            let resolution = FanControlResolver.resolve(
                policy: policy,
                sensorCelsius: sensorCelsius(for: policy, fallback: socCelsius),
                pressure: pressure,
                limits: descriptor.limits,
                memory: memory[descriptor.index]
            )

            // Remember what drove this decision so the next tick's
            // hysteresis check has an anchor. Only a genuine target is
            // remembered — remembering a `.deferToSystem` or an
            // `.unavailable` would let a later curve reading be "held"
            // against a target that was never chosen.
            if let rpm = resolution.targetRPM,
               let celsius = sensorCelsius(for: policy, fallback: socCelsius),
               !resolution.heldByHysteresis {
                memory[descriptor.index] = FanResolutionMemory(celsius: celsius, rpm: rpm)
            }

            return FanState(descriptor: descriptor, speed: speed, resolution: resolution)
        }
    }

    /// The temperature driving a policy's curve: the named sensor if the
    /// user picked one and it's present in this sample, otherwise the
    /// hottest reading (matching `HIDSensorBridge.readTemperature()`'s own
    /// max-not-average choice), otherwise `nil`.
    ///
    /// **A named sensor that has gone missing resolves to `nil`, not to the
    /// hottest one.** Silently re-binding a curve to a different sensor
    /// than the user chose would change what the curve means without
    /// telling anyone; `nil` produces a visible "no reading available"
    /// state instead.
    func sensorCelsius(for policy: FanControlPolicy, fallback: Double?) -> Double? {
        if let name = policy.sensorName {
            return availableSensors.first { $0.name == name }?.celsius
        }
        return availableSensors.map(\.celsius).max() ?? fallback
    }

    // MARK: - Apply

    /// Applies one fan's resolved policy through the backend — a real SMC
    /// write when the privileged helper is live. Pro-gated first: the
    /// entitlement question outranks every parameter question, and the
    /// error carries the availability so the reason a user sees is
    /// produced by the layer that actually knows it rather than by a
    /// string in the view.
    public func applyPolicy(forFan index: Int) throws {
        guard isProUnlocked else {
            throw FanControlWriteError.writesUnavailable(.requiresPro)
        }
        guard capability.fans.contains(where: { $0.index == index }) else {
            throw FanControlWriteError.unknownFan(index: index)
        }
        let policy = settings.policy(forFan: index)
        let descriptor = capability.fans.first { $0.index == index }
        let resolution = FanControlResolver.resolve(
            policy: policy,
            sensorCelsius: sensorCelsius(for: policy, fallback: nil),
            pressure: pressure,
            limits: descriptor?.limits,
            memory: memory[index]
        )
        switch resolution.outcome {
        case .deferToSystem:
            try backend.revertToAuto(fan: index)
        case .target(let rpm):
            try backend.applyTarget(rpm: rpm, toFan: index)
        case .unavailable(let reason):
            // Not a write failure — the policy never produced a request to
            // begin with. Its own error case rather than folded into
            // `writesUnavailable`, which would blame the missing helper for
            // a curve that has no sensor.
            throw FanControlWriteError.policyProducedNoTarget(reason: reason)
        }
    }

    /// Hands one fan back to the firmware. Deliberately NOT Pro-gated —
    /// same lapse-survival reason as `revertAllToAuto`.
    public func revertToAuto(fan index: Int) throws {
        guard capability.fans.contains(where: { $0.index == index }) else {
            throw FanControlWriteError.unknownFan(index: index)
        }
        try backend.revertToAuto(fan: index)
    }
}
