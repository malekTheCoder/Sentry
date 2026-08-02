import Foundation

// MARK: - Fan control model types (fan-control plan §5.1, §6)
//
// Everything in this file is pure value-type logic: no IOKit, no SMC, no
// writes, nothing platform-specific. That is deliberate and load-bearing.
//
// The fan-control feature's Phase 1 spike (`docs/fan-control-spike.md`,
// measured on MacBookPro18,3) established the shape of the problem:
// *reading* SMC fan keys needs no privileges and already ships
// (`SystemMetricsKit/Bridges/SMCFanBridge.swift` → `ThermalCollector`),
// while *writing* them requires root through a privileged helper
// (`SMAppService` LaunchDaemon) that does not exist in this build and is
// not being built here. Phase 2 — this change — builds the shell that a
// future write backend slots into: the model types, the persisted
// settings, capability detection, and a Settings surface that is honest
// about the fact that nothing here can move a fan yet.
//
// Keeping the arithmetic (interpolation, clamping, hysteresis, safety
// ceiling) in pure types means all of it is unit-testable today, on any
// Mac including a fanless one, years before there is a write path to
// exercise it against — the same posture `SyncService`'s cadence functions
// take toward a CloudKit container that doesn't exist yet.

// MARK: - Mode

/// The four control modes from plan §6.
///
/// **`auto` is not "off" — it is the machine's own control loop**, which is
/// what every Mac is running right now and what Sentry has never once
/// interfered with. That distinction matters for honesty: selecting `auto`
/// on a Mac that has never been written to is a no-op *because nothing
/// needed to change*, not because the control failed. Selecting anything
/// else is a request Sentry cannot fulfil in this build, and every surface
/// that offers those cases has to say so — see `requiresPrivilegedWrite`.
public enum FanControlMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// macOS/SMC firmware manages fan speed. The default, the fallback, and
    /// the only mode this build can truthfully claim to be in.
    case auto

    /// A fixed target RPM (plan §6.2).
    case manual

    /// Target RPM interpolated from a chosen sensor's temperature through a
    /// `FanCurve` (plan §6.3).
    case sensorCurve

    /// `manual` or `sensorCurve` plus an emergency override: thermal
    /// pressure at serious/critical, or a sensor above the safety ceiling,
    /// forces maximum RPM (plan §6.4).
    case hybrid

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .manual: return "Fixed speed"
        case .sensorCurve: return "Sensor curve"
        case .hybrid: return "Sensor curve with safety override"
        }
    }

    /// One sentence describing what the mode *would* do. Written in the
    /// conditional ("would", "will") rather than the present tense on
    /// purpose: none of these modes except `.auto` is in effect in this
    /// build, and copy that says "keeps fans at…" would read as a
    /// description of current behavior.
    public var explanation: String {
        switch self {
        case .auto:
            return "The Mac's own firmware decides fan speed. This is what's happening right now, and what Sentry has never changed."
        case .manual:
            return "Would hold every fan at one fixed speed, clamped to the range the SMC reports for that fan."
        case .sensorCurve:
            return "Would set fan speed from a temperature sensor, interpolating between the curve's points."
        case .hybrid:
            return "Would follow the curve, but jump to maximum whenever thermal pressure turns serious or a sensor passes the safety ceiling."
        }
    }

    /// Whether entering this mode requires writing an SMC key — i.e.
    /// requires root, i.e. requires the privileged helper this build does
    /// not have.
    ///
    /// `auto` is `false` **only on a Mac that was never taken out of auto**,
    /// which is every Mac running this build, because no write path exists
    /// to have taken it out. Once Phase 3 lands, "return to auto" becomes a
    /// real write (`F{i}Md = 0`) and this property's contract has to be
    /// re-read at that point — see this file's header note. It is spelled
    /// as a mode property rather than hardcoded in the UI so there is
    /// exactly one place to change.
    public var requiresPrivilegedWrite: Bool {
        self != .auto
    }
}

// MARK: - Hardware limits

/// The RPM range the SMC itself reports for one fan (`F{i}Mn` / `F{i}Mx`).
///
/// **Why these come from hardware rather than a constant table.** The spike
/// measured 1200–5779 RPM on fan 0 and 1200–6241 on fan 1 of the *same*
/// machine — the two fans in one laptop do not share a ceiling, and no
/// hardcoded number could be right for both, let alone across models. Plan
/// §13's "users lock fans too low" risk is mitigated by clamping to these
/// values, never to a guess.
public struct FanHardwareLimits: Codable, Equatable, Sendable {
    public var minRPM: Double
    public var maxRPM: Double

    public init(minRPM: Double, maxRPM: Double) {
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// Plan §5.3's first validation rule, as a property rather than an
    /// assertion: a nonsensical pair read from a malfunctioning SMC (or a
    /// hand-edited settings file) must be *detectable* and reportable, not
    /// silently repaired by swapping the two numbers — a silent swap would
    /// turn "this reading is wrong" into "this reading is fine", which is
    /// the fabrication this codebase refuses.
    public var isValid: Bool {
        minRPM.isFinite && maxRPM.isFinite && minRPM >= 0 && minRPM <= maxRPM
    }

    /// Confines an RPM to the hardware's own range. Returns the input
    /// unchanged when the limits are invalid — clamping to a range that
    /// makes no sense would be worse than not clamping, and the caller has
    /// `isValid` to check first.
    public func clamp(_ rpm: Double) -> Double {
        guard isValid, rpm.isFinite else { return rpm }
        return Swift.min(Swift.max(rpm, minRPM), maxRPM)
    }

    /// The RPM at `fraction` of the way from `minRPM` to `maxRPM`. Used by
    /// `FanControlPreset` so presets are expressed as "40% of this fan's
    /// range" rather than as absolute numbers that would be wrong on any
    /// machine but the one they were written on.
    public func rpm(atFraction fraction: Double) -> Double {
        guard isValid, fraction.isFinite else { return minRPM }
        let bounded = Swift.min(Swift.max(fraction, 0), 1)
        return minRPM + (maxRPM - minRPM) * bounded
    }
}

// MARK: - Curve

/// One breakpoint of a fan curve: at `celsius`, request `rpm`.
public struct FanCurvePoint: Codable, Equatable, Sendable {
    public var celsius: Double
    public var rpm: Double

    public init(celsius: Double, rpm: Double) {
        self.celsius = celsius
        self.rpm = rpm
    }
}

/// Something wrong with a curve, in a form the UI can print verbatim.
///
/// Curves are *reported* invalid rather than silently corrected, for the
/// same reason `FanHardwareLimits.isValid` exists: a curve editor that
/// quietly reorders or rewrites the user's points teaches the user that
/// their edits don't stick, and a curve that was auto-repaired into
/// something safe-looking hides a real mistake. The one normalization that
/// *is* applied — sorting by temperature — is documented on `FanCurve.init`
/// and is order-only, never value-changing.
public enum FanCurveIssue: Equatable, Sendable {
    case empty
    case duplicateTemperature(celsius: Double)
    /// Plan §5.3: "curves must be monotonically sensible." A curve whose
    /// RPM *falls* as temperature rises would spin fans down as the Mac
    /// heats up.
    case rpmFallsAsTemperatureRises(fromCelsius: Double, toCelsius: Double)
    case rpmOutsideHardwareLimits(celsius: Double, rpm: Double, limits: FanHardwareLimits)
    case nonFiniteValue

    public var message: String {
        switch self {
        case .empty:
            return "A curve needs at least one point."
        case .duplicateTemperature(let celsius):
            return "Two points share \(Int(celsius.rounded())) °C — each temperature can appear only once."
        case .rpmFallsAsTemperatureRises(let from, let to):
            return "Speed drops between \(Int(from.rounded())) °C and \(Int(to.rounded())) °C — a curve should never slow the fans down as the Mac gets hotter."
        case .rpmOutsideHardwareLimits(let celsius, let rpm, let limits):
            return "\(Int(rpm.rounded())) rpm at \(Int(celsius.rounded())) °C is outside this fan's \(Int(limits.minRPM.rounded()))–\(Int(limits.maxRPM.rounded())) rpm range."
        case .nonFiniteValue:
            return "A point has a temperature or speed that isn't a real number."
        }
    }
}

/// A temperature→RPM mapping (plan §5.1, §6.3, §7.3).
///
/// **Points are kept sorted by temperature, and that is the only thing
/// `init` changes.** Interpolation over an unsorted list would produce
/// garbage, and a curve editor that lets the user drag a point past its
/// neighbour has to end up sorted somehow; sorting is order-only and loses
/// nothing, whereas dropping or rewriting points would. Everything else
/// wrong with a curve (duplicates, falling RPM, out-of-range values) is
/// surfaced by `issues(against:)` for the UI to show, not fixed silently.
public struct FanCurve: Codable, Equatable, Sendable {

    public private(set) var points: [FanCurvePoint]

    private enum CodingKeys: String, CodingKey {
        case points
    }

    public init(points: [FanCurvePoint]) {
        self.points = points.sorted { $0.celsius < $1.celsius }
    }

    /// Hand-written so a curve loaded from `settings.json` goes through the
    /// same sorting `init(points:)` applies. Synthesized `Codable` would
    /// assign `points` directly and hand `targetRPM(atCelsius:)` an
    /// unsorted array from any hand-edited file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([FanCurvePoint].self, forKey: .points))
    }

    /// Linear interpolation between the two bracketing points, held flat
    /// outside the curve's ends.
    ///
    /// **Returns `nil` for an empty curve rather than a default RPM.** A
    /// curve with no points expresses no opinion about fan speed, and
    /// inventing one (0? minimum? maximum?) would be exactly the fabricated
    /// reading this codebase forbids. Callers turn `nil` into a visible
    /// "this curve can't produce a target" state.
    public func targetRPM(atCelsius celsius: Double) -> Double? {
        guard celsius.isFinite, !points.isEmpty else { return nil }

        // Flat-held ends: below the first breakpoint the curve's own
        // minimum applies, above the last its maximum does. Extrapolating
        // past the ends would let a curve request an RPM the user never
        // drew, which at the hot end is precisely where a mistake is most
        // expensive.
        guard let first = points.first, let last = points.last else { return nil }
        if celsius <= first.celsius { return first.rpm }
        if celsius >= last.celsius { return last.rpm }

        for index in 0..<(points.count - 1) {
            let lower = points[index]
            let upper = points[index + 1]
            guard celsius >= lower.celsius, celsius <= upper.celsius else { continue }
            let span = upper.celsius - lower.celsius
            // Two points at the same temperature is a `duplicateTemperature`
            // issue, reported elsewhere; here it just must not divide by zero.
            guard span > 0 else { return upper.rpm }
            let t = (celsius - lower.celsius) / span
            return lower.rpm + (upper.rpm - lower.rpm) * t
        }
        return last.rpm
    }

    /// Everything wrong with this curve, in the order a reader would notice
    /// it. `limits` is optional because a Mac whose `F{i}Mn`/`F{i}Mx` keys
    /// couldn't be read still deserves the structural checks — we just
    /// can't range-check against hardware we failed to interrogate, and
    /// pretending otherwise (say, against a hardcoded 0–6000) would invent
    /// a limit.
    public func issues(against limits: FanHardwareLimits? = nil) -> [FanCurveIssue] {
        var issues: [FanCurveIssue] = []

        guard !points.isEmpty else { return [.empty] }

        if points.contains(where: { !$0.celsius.isFinite || !$0.rpm.isFinite }) {
            issues.append(.nonFiniteValue)
        }

        for index in 0..<(points.count - 1) {
            let lower = points[index]
            let upper = points[index + 1]
            if lower.celsius == upper.celsius {
                issues.append(.duplicateTemperature(celsius: lower.celsius))
            }
            if upper.rpm < lower.rpm {
                issues.append(
                    .rpmFallsAsTemperatureRises(fromCelsius: lower.celsius, toCelsius: upper.celsius)
                )
            }
        }

        if let limits, limits.isValid {
            for point in points where point.rpm.isFinite {
                if point.rpm < limits.minRPM || point.rpm > limits.maxRPM {
                    issues.append(
                        .rpmOutsideHardwareLimits(celsius: point.celsius, rpm: point.rpm, limits: limits)
                    )
                }
            }
        }

        return issues
    }

    /// A copy with every point's RPM confined to the hardware range.
    /// Deliberately *not* applied automatically anywhere — `issues(against:)`
    /// exists so the UI can tell the user their curve exceeds the hardware
    /// instead of quietly moving their points. This is the explicit "fix it
    /// for me" operation a future curve editor's button would call.
    public func clamped(to limits: FanHardwareLimits) -> FanCurve {
        guard limits.isValid else { return self }
        return FanCurve(points: points.map {
            FanCurvePoint(celsius: $0.celsius, rpm: limits.clamp($0.rpm))
        })
    }
}

// MARK: - Presets

/// Plan §4's one-click presets, expressed as *fractions* of each fan's own
/// measured range rather than absolute RPMs (see `FanHardwareLimits`).
///
/// The temperature breakpoints (50/70/85/95 °C) are plan §6.3's example
/// curve verbatim. They are a starting shape for a user to edit, not a
/// tuning claim: nothing in the spike measured which RPM is "right" at
/// 70 °C on any particular Mac, and this file does not pretend otherwise.
public enum FanControlPreset: String, Codable, CaseIterable, Equatable, Sendable {
    case quiet
    case balanced
    case performance
    case turbo

    public var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        case .turbo: return "Turbo"
        }
    }

    /// RPM fractions at 50/70/85/95 °C.
    var fractions: [Double] {
        switch self {
        case .quiet: return [0.0, 0.15, 0.45, 1.0]
        case .balanced: return [0.0, 0.30, 0.65, 1.0]
        case .performance: return [0.20, 0.55, 0.85, 1.0]
        case .turbo: return [0.50, 0.80, 1.0, 1.0]
        }
    }

    public static let breakpointsCelsius: [Double] = [50, 70, 85, 95]

    /// The preset's curve for one fan's actual range.
    public func curve(for limits: FanHardwareLimits) -> FanCurve {
        FanCurve(points: zip(Self.breakpointsCelsius, fractions).map { celsius, fraction in
            FanCurvePoint(celsius: celsius, rpm: limits.rpm(atFraction: fraction))
        })
    }
}

// MARK: - Policy

/// Everything that decides one fan's target speed (plan §5.1's
/// `FanControlPolicy`). Persisted verbatim inside `FanControlSettings`.
public struct FanControlPolicy: Codable, Equatable, Sendable {

    public var mode: FanControlMode

    /// The fixed target for `.manual`. `nil` means "the user hasn't chosen
    /// one", which is a different state from "0" and must stay different:
    /// `FanControlResolver` reports `.unavailable` for the former rather
    /// than requesting a number nobody picked.
    public var manualTargetRPM: Double?

    /// Breakpoints for `.sensorCurve` / `.hybrid`.
    public var curve: FanCurve

    /// Which `ThermalSensorReading.name` drives the curve. `nil` means
    /// "hottest available sensor", the same max-not-average choice
    /// `HIDSensorBridge.readTemperature()` already makes and for the same
    /// reason: one hot cluster is what throttling actually responds to.
    public var sensorName: String?

    /// Plan §5.3's anti-flap rule. The resolver holds the previous target
    /// until the driving sensor has moved at least this far from the
    /// temperature that produced it, so a sensor jittering by a degree
    /// doesn't produce an audible fan oscillation.
    public var hysteresisCelsius: Double

    /// Plan §6.4's hard ceiling. At or above this temperature `.hybrid`
    /// abandons the curve and requests maximum RPM.
    public var safetyCeilingCelsius: Double

    public init(
        mode: FanControlMode = .auto,
        manualTargetRPM: Double? = nil,
        curve: FanCurve = FanControlPolicy.defaultCurve,
        sensorName: String? = nil,
        hysteresisCelsius: Double = 3,
        safetyCeilingCelsius: Double = 95
    ) {
        self.mode = mode
        self.manualTargetRPM = manualTargetRPM
        self.curve = curve
        self.sensorName = sensorName
        self.hysteresisCelsius = hysteresisCelsius
        self.safetyCeilingCelsius = safetyCeilingCelsius
    }

    /// The shipped curve shape, in *fractions expressed as RPM against a
    /// nominal 1200–6000 range*. It exists so `AppSettings.default` has
    /// something concrete to round-trip; the moment real limits are known,
    /// `FanControlPreset.balanced.curve(for:)` produces the same shape
    /// against the actual hardware and the UI offers that as a one-click
    /// action. It is deliberately not presented anywhere as "your Mac's
    /// curve" — no hardware was consulted to produce it.
    public static let defaultCurve = FanControlPreset.balanced.curve(
        for: FanHardwareLimits(minRPM: 1200, maxRPM: 6000)
    )

    private enum CodingKeys: String, CodingKey {
        case mode
        case manualTargetRPM
        case curve
        case sensorName
        case hysteresisCelsius
        case safetyCeilingCelsius
    }

    /// Same additive contract as `AppSettings.init(from:)` and
    /// `FanControlSettings.init(from:)`: every key optional so a policy
    /// written by an older build keeps decoding when a field is added here
    /// later. `manualTargetRPM` and `sensorName` stay genuinely optional
    /// values — absent means "not chosen", which the resolver reports
    /// rather than filling in.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FanControlPolicy()
        self.init(
            mode: try container.decodeIfPresent(FanControlMode.self, forKey: .mode)
                ?? fallback.mode,
            manualTargetRPM: try container.decodeIfPresent(Double.self, forKey: .manualTargetRPM),
            curve: try container.decodeIfPresent(FanCurve.self, forKey: .curve)
                ?? fallback.curve,
            sensorName: try container.decodeIfPresent(String.self, forKey: .sensorName),
            hysteresisCelsius: try container.decodeIfPresent(Double.self, forKey: .hysteresisCelsius)
                ?? fallback.hysteresisCelsius,
            safetyCeilingCelsius: try container.decodeIfPresent(Double.self, forKey: .safetyCeilingCelsius)
                ?? fallback.safetyCeilingCelsius
        )
    }
}

// MARK: - Persisted settings

/// One fan's deviation from `FanControlSettings.defaultPolicy` (plan §5.2's
/// "per-fan settings").
///
/// An array of index-tagged values rather than `[Int: FanControlPolicy]`
/// because a `Dictionary` with a non-`String` key round-trips through
/// `Codable` as a flat array-of-alternating-pairs, which is a hostile shape
/// in a `settings.json` a user might open — the same reasoning
/// `AppSettings.mcpEnabledToolIDs` records for storing a `Set<String>`
/// rather than a `[MCPToolID: Bool]`.
public struct FanPolicyOverride: Codable, Equatable, Sendable {
    public var fanIndex: Int
    public var policy: FanControlPolicy

    public init(fanIndex: Int, policy: FanControlPolicy) {
        self.fanIndex = fanIndex
        self.policy = policy
    }
}

/// The persisted fan-control block (plan §5.2), carried inside
/// `AppSettings` as a single nested value rather than a dozen top-level
/// fields — it round-trips as one `"fanControl": { … }` object, keeping the
/// settings file readable and giving `AppSettings.init(from:)` exactly one
/// additive key to defend.
///
/// **Every default here describes a machine nothing has touched.**
/// `defaultPolicy.mode` is `.auto` and `controlEnabledOnLaunch` is `false`,
/// so an existing install that upgrades into a build containing this key
/// gains no behavior at all — which is the truth, because this build has no
/// write path. `restoreAutoOnLaunch` is `true` for plan §8's "if state is
/// ambiguous, default to Auto" rule, and is stored now so Phase 3's startup
/// recovery has a user-visible setting to obey instead of inventing one.
public struct FanControlSettings: Codable, Equatable, Sendable {

    public var defaultPolicy: FanControlPolicy
    public var perFanOverrides: [FanPolicyOverride]

    /// Plan §5.2's "whether control is enabled on launch". Independent of
    /// `defaultPolicy.mode`: a user can compose a curve they intend to use
    /// without arming it, and arming is the decision worth persisting
    /// separately.
    public var controlEnabledOnLaunch: Bool

    /// Plan §5.2's "startup behavior" / §8's recovery path: hand the fans
    /// back to the firmware at launch unless the app can prove it was the
    /// last controller.
    public var restoreAutoOnLaunch: Bool

    private enum CodingKeys: String, CodingKey {
        case defaultPolicy
        case perFanOverrides
        case controlEnabledOnLaunch
        case restoreAutoOnLaunch
    }

    public init(
        defaultPolicy: FanControlPolicy = FanControlPolicy(),
        perFanOverrides: [FanPolicyOverride] = [],
        controlEnabledOnLaunch: Bool = false,
        restoreAutoOnLaunch: Bool = true
    ) {
        self.defaultPolicy = defaultPolicy
        self.perFanOverrides = perFanOverrides
        self.controlEnabledOnLaunch = controlEnabledOnLaunch
        self.restoreAutoOnLaunch = restoreAutoOnLaunch
    }

    /// The policy governing one fan: its override if it has one, otherwise
    /// the default. A duplicate index in a hand-edited file resolves to the
    /// first entry rather than throwing — a settings file is not a place to
    /// crash over.
    public func policy(forFan index: Int) -> FanControlPolicy {
        perFanOverrides.first { $0.fanIndex == index }?.policy ?? defaultPolicy
    }

    /// Sets one fan's override, replacing an existing entry in place so the
    /// array can't accumulate duplicates for the same index.
    public mutating func setPolicy(_ policy: FanControlPolicy, forFan index: Int) {
        if let position = perFanOverrides.firstIndex(where: { $0.fanIndex == index }) {
            perFanOverrides[position].policy = policy
        } else {
            perFanOverrides.append(FanPolicyOverride(fanIndex: index, policy: policy))
        }
    }

    /// Drops one fan's override so it follows `defaultPolicy` again.
    public mutating func clearPolicy(forFan index: Int) {
        perFanOverrides.removeAll { $0.fanIndex == index }
    }

    /// Same additive-`Codable` discipline as `AppSettings.init(from:)`:
    /// every key optional, every absence falling back to the shipped
    /// default. A settings file written by a build from before per-fan
    /// overrides existed must still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FanControlSettings()
        self.init(
            defaultPolicy: try container.decodeIfPresent(FanControlPolicy.self, forKey: .defaultPolicy)
                ?? fallback.defaultPolicy,
            perFanOverrides: try container.decodeIfPresent([FanPolicyOverride].self, forKey: .perFanOverrides)
                ?? fallback.perFanOverrides,
            controlEnabledOnLaunch: try container.decodeIfPresent(Bool.self, forKey: .controlEnabledOnLaunch)
                ?? fallback.controlEnabledOnLaunch,
            restoreAutoOnLaunch: try container.decodeIfPresent(Bool.self, forKey: .restoreAutoOnLaunch)
                ?? fallback.restoreAutoOnLaunch
        )
    }
}

// MARK: - Resolution

/// What a policy asks for, given a moment's sensor readings — the pure
/// core of plan §4.1's "compute target RPMs from mode + curve", split out
/// from the service so it can be tested with no hardware, no backend, and
/// no `ObservableObject` involved.
///
/// **This type computes a request. Nothing here applies one.** In this
/// build nothing *can* — see `FanControlBackend`.
public struct FanTargetResolution: Equatable, Sendable {

    public enum Outcome: Equatable, Sendable {
        /// `.auto`: no target at all, because the firmware owns the fan.
        /// Distinct from `.unavailable` — this is a deliberate hand-off,
        /// not a failure.
        case deferToSystem
        case target(rpm: Double)
        /// The policy asked for something that couldn't be computed. The
        /// reason is a sentence because it is shown to the user verbatim.
        case unavailable(reason: String)
    }

    public var outcome: Outcome
    /// The request was pulled into the hardware's own `F{i}Mn`/`F{i}Mx`
    /// range. Surfaced rather than swallowed: a user who typed 8000 rpm
    /// should be told their fan tops out at 6241, not left believing the
    /// number they typed is in effect.
    public var wasClamped: Bool
    /// Plan §6.4's override fired — the curve was abandoned for maximum RPM.
    public var safetyCeilingEngaged: Bool
    /// Hysteresis held the previous target instead of following the sensor.
    public var heldByHysteresis: Bool

    public init(
        outcome: Outcome,
        wasClamped: Bool = false,
        safetyCeilingEngaged: Bool = false,
        heldByHysteresis: Bool = false
    ) {
        self.outcome = outcome
        self.wasClamped = wasClamped
        self.safetyCeilingEngaged = safetyCeilingEngaged
        self.heldByHysteresis = heldByHysteresis
    }

    /// Convenience for tests and UI: the RPM, or `nil` for the two
    /// non-numeric outcomes.
    public var targetRPM: Double? {
        if case .target(let rpm) = outcome { return rpm }
        return nil
    }
}

/// The previous decision, fed back in so hysteresis has something to hold
/// against. Carried explicitly as a parameter rather than stored on the
/// resolver so the resolver stays a pure function — `AlertRule`'s "keep all
/// runtime state off the rule" convention, applied to fan curves.
public struct FanResolutionMemory: Equatable, Sendable {
    public var celsius: Double
    public var rpm: Double

    public init(celsius: Double, rpm: Double) {
        self.celsius = celsius
        self.rpm = rpm
    }
}

/// Pure policy → target arithmetic. No state, no I/O, no writes.
public enum FanControlResolver {

    /// The target `policy` asks for at this moment.
    ///
    /// - Parameters:
    ///   - policy: the mode/curve/ceiling in force for this fan.
    ///   - sensorCelsius: the driving sensor's reading, or `nil` when no
    ///     sensor could be read. `nil` is not treated as "cold" — a curve
    ///     with no input resolves to `.unavailable`, because guessing a
    ///     temperature to feed a fan curve is the most dangerous possible
    ///     fabrication in this feature.
    ///   - pressure: `ThermalStats.PressureLevel`, which `.hybrid` consults
    ///     independently of the numeric ceiling. `ProcessInfo.thermalState`
    ///     is available on every Mac even when no temperature sensor is, so
    ///     this path can still fire when `sensorCelsius` is `nil`.
    ///   - limits: the fan's own SMC-reported range, or `nil` when those
    ///     keys couldn't be read (no clamping is then possible, and
    ///     `wasClamped` stays false rather than claiming a clamp happened).
    ///   - memory: the previous resolution for this fan, for hysteresis.
    public static func resolve(
        policy: FanControlPolicy,
        sensorCelsius: Double?,
        pressure: ThermalStats.PressureLevel,
        limits: FanHardwareLimits?,
        memory: FanResolutionMemory? = nil
    ) -> FanTargetResolution {

        switch policy.mode {
        case .auto:
            return FanTargetResolution(outcome: .deferToSystem)

        case .manual:
            guard let requested = policy.manualTargetRPM, requested.isFinite else {
                return FanTargetResolution(
                    outcome: .unavailable(reason: "No fixed speed has been chosen yet.")
                )
            }
            let (clamped, wasClamped) = applyLimits(requested, limits)
            return FanTargetResolution(outcome: .target(rpm: clamped), wasClamped: wasClamped)

        case .sensorCurve, .hybrid:
            let ceilingFromPressure = policy.mode == .hybrid
                && (pressure == .serious || pressure == .critical)
            let ceilingFromTemperature = policy.mode == .hybrid
                && (sensorCelsius.map { $0 >= policy.safetyCeilingCelsius } ?? false)

            if ceilingFromPressure || ceilingFromTemperature {
                // The one branch that ignores the curve entirely. Note it
                // needs `limits` to know what "maximum" means: with no
                // readable ceiling there is no maximum to request, and
                // inventing one would be a fabricated number aimed at the
                // hardware.
                guard let limits, limits.isValid else {
                    return FanTargetResolution(
                        outcome: .unavailable(
                            reason: "The safety override wants maximum speed, but this Mac's fan limits couldn't be read."
                        ),
                        safetyCeilingEngaged: true
                    )
                }
                return FanTargetResolution(
                    outcome: .target(rpm: limits.maxRPM),
                    safetyCeilingEngaged: true
                )
            }

            guard let celsius = sensorCelsius else {
                return FanTargetResolution(
                    outcome: .unavailable(reason: "No temperature reading is available to drive the curve.")
                )
            }

            // Hysteresis: hold the previous target while the sensor stays
            // within `hysteresisCelsius` of where it was when that target
            // was chosen. Checked before interpolation so the held value is
            // exactly the previous one, not a re-derived approximation.
            if let memory,
               policy.hysteresisCelsius > 0,
               abs(celsius - memory.celsius) < policy.hysteresisCelsius {
                let (clamped, wasClamped) = applyLimits(memory.rpm, limits)
                return FanTargetResolution(
                    outcome: .target(rpm: clamped),
                    wasClamped: wasClamped,
                    heldByHysteresis: true
                )
            }

            guard let curveRPM = policy.curve.targetRPM(atCelsius: celsius) else {
                return FanTargetResolution(
                    outcome: .unavailable(reason: "This curve has no points, so it can't produce a target speed.")
                )
            }
            let (clamped, wasClamped) = applyLimits(curveRPM, limits)
            return FanTargetResolution(outcome: .target(rpm: clamped), wasClamped: wasClamped)
        }
    }

    /// Clamps and reports whether it had to. `wasClamped` is false when
    /// there are no usable limits — nothing was clamped, so saying it was
    /// would be a small lie in a feature that can't afford any.
    private static func applyLimits(
        _ rpm: Double,
        _ limits: FanHardwareLimits?
    ) -> (rpm: Double, wasClamped: Bool) {
        guard let limits, limits.isValid else { return (rpm, false) }
        let clamped = limits.clamp(rpm)
        return (clamped, clamped != rpm)
    }
}
