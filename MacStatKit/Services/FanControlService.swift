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

/// Plan §4.1's fan control service — the Phase 2 half of it.
///
/// **What this actually does, stated plainly: it reads, it computes, and it
/// refuses.** It reads real fan speeds through whichever `FanControlBackend`
/// it was handed (on a Mac, `SMCReadOnlyFanControlBackend` over the
/// already-shipped `SMCFanBridge`). It computes what the user's persisted
/// policy would request, through the pure `FanControlResolver`. And when
/// asked to actually apply any of that, it throws — because no backend in
/// this build can write an SMC key, which needs root and a privileged
/// helper that has not been built (`docs/fan-control-spike.md`).
///
/// **Why the apply path exists at all in a build that can't apply
/// anything.** So the failure is a real, typed, surfaced error rather than
/// a missing method that the UI works around with a disabled button and a
/// comment. `applyPolicy(forFan:)` throwing `FanControlWriteError
/// .writesUnavailable(.needsPrivilegedHelper)` is testable today and is the
/// same call the Settings pane would make if the control were enabled — so
/// there is no untested gap between "the button is greyed out" and "the
/// write is impossible."
///
/// **What was deliberately not built here.**
///  - No timer, no polling loop of its own. Snapshots arrive via
///    `ingest(_:)` from the one `StatsCoordinator` stream every other
///    consumer reads (plan §3.2 P3). A service that armed its own
///    `DispatchSourceTimer` to sample fans it cannot control would burn
///    cycles on every user's Mac for nothing — the same trade `SyncPane`
///    documents refusing for `SyncService`.
///  - No watchdog, no auto-revert-on-quit, no startup recovery. All three
///    are plan §8 requirements and all three are meaningless before a write
///    exists: there is nothing to revert, because nothing was ever changed.
///    `FanControlSettings.restoreAutoOnLaunch` persists the *user's
///    preference* about that behavior so Phase 3 has a setting to obey, and
///    that is as far as this change goes.
///  - No menu bar / dropdown surface (plan §7.1). A dropdown section whose
///    every control is disabled is noise in the surface users look at most
///    often; the honest disclosure belongs in Settings until there is
///    something to toggle.
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

    /// Hysteresis memory, per fan index. Kept here rather than in
    /// `FanControlResolver` so the resolver stays a pure function of its
    /// inputs (see its doc comment).
    private var memory: [Int: FanResolutionMemory] = [:]

    public init(backend: FanControlBackend, settings: FanControlSettings = FanControlSettings()) {
        self.backend = backend
        self.settings = settings
        self.capability = backend.capability()
    }

    /// The backend's own answer about writes, forwarded unchanged. The
    /// Settings pane renders `writeAvailability.explanation` verbatim next
    /// to every disabled control.
    public var writeAvailability: FanWriteAvailability {
        backend.writeAvailability
    }

    public var backendIdentifier: String { backend.identifier }

    /// Re-probes the hardware. Worth offering only for the `.unreadable`
    /// case — a fanless Mac will not grow fans, so the UI exposes this as a
    /// "Try again" affordance on that state alone.
    public func refreshCapability() {
        capability = backend.capability()
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

    // MARK: - Apply (throws, always, in this build)

    /// Would apply one fan's resolved policy. Throws in this build, always.
    ///
    /// The error carries the backend's own `FanWriteAvailability`, so the
    /// reason a user sees is produced by the layer that actually knows it
    /// rather than by a string in the view.
    public func applyPolicy(forFan index: Int) throws {
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

    /// Would hand one fan back to the firmware. Throws in this build,
    /// always — and note that on this build the fans have never left the
    /// firmware's control, so there is nothing to hand back.
    public func revertToAuto(fan index: Int) throws {
        guard capability.fans.contains(where: { $0.index == index }) else {
            throw FanControlWriteError.unknownFan(index: index)
        }
        try backend.revertToAuto(fan: index)
    }
}
