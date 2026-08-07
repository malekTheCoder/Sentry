import Foundation

/// The preflight *contract* behind `preflight_check` and `wait_until_ready`
/// — a pure function of the current `SystemSnapshot` (plus a few explicit
/// inputs the snapshot doesn't carry) onto a four-level verdict an agent can
/// branch on without natural-language parsing.
///
/// **Why this exists next to `SystemAdvisor` rather than replacing it.**
/// `SystemAdvisor.recommend` answers "go or wait" as prose — good enough for
/// a human skimming `sentryctl check`, but a binary verdict flattens three
/// distinctions an autonomous agent actually needs: *"start, but expect
/// contention"* (caution), *"waiting will genuinely fix this"* (wait), and
/// *"waiting fixes nothing — don't start at all"* (do_not_start, e.g. a
/// battery about to die). This type carries those as an enum plus
/// machine-readable reason codes; `SystemAdvisor` keeps the threshold
/// constants both share, so the two can never disagree about where a
/// boundary sits.
///
/// **Why pure.** Same reason as `SystemAdvisor`: every verdict boundary is
/// unit-testable without a live sensor, and `WaitCondition.ready` (the
/// polling side of the same contract) can call the identical function on
/// each snapshot tick — the invariant "`wait_until_ready` returns when
/// `preflight_check` would stop saying wait" holds by construction, and
/// `AgentPreflightTests` pins it anyway.
public enum AgentPreflight {

    // MARK: - Thresholds
    //
    // Thermal/CPU/low-battery boundaries are `SystemAdvisor`'s constants
    // (which themselves mirror `AlertEngine.defaultRules`) — see that type's
    // doc comment for why they live there. Only the boundaries this policy
    // adds beyond `SystemAdvisor`'s vocabulary are defined here.

    /// Below this, on battery, the verdict is `do_not_start` rather than
    /// `wait`: waiting doesn't recharge a battery, and a heavy workload
    /// started at single-digit charge is more likely to die mid-run (taking
    /// unsaved agent work with it) than to finish. Half of
    /// `SystemAdvisor.lowBatteryPercent` (20%), which stays the `wait`
    /// boundary — between the two, an agent still has time to ask the user
    /// to plug in.
    public static let criticalBatteryPercent: Double = 10

    // MARK: - Verdict

    /// Ordered by escalating severity — `combined(with:)` below relies on
    /// the declaration order via `rank`. Raw values are the wire strings
    /// (`do_not_start`, not `doNotStart`): they're what an agent's prompt
    /// will match against, so they follow the tool-name convention
    /// (snake_case) rather than Swift's.
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case proceed
        case caution
        case wait
        case doNotStart = "do_not_start"

        /// Position in the severity ladder, for taking the max of several
        /// reasons' severities. Not `Comparable` conformance — nothing else
        /// should be ordering verdicts, and `<` on a wire enum invites
        /// callers to invent their own thresholds.
        var rank: Int {
            switch self {
            case .proceed: return 0
            case .caution: return 1
            case .wait: return 2
            case .doNotStart: return 3
            }
        }

        func combined(with other: Verdict) -> Verdict {
            rank >= other.rank ? self : other
        }
    }

    // MARK: - Reasons

    /// Stable machine-readable codes — like `MCPToolID` raw values, these
    /// cross the wire and end up in agents' prompts/scripts, so **never
    /// rename a raw value after shipping**. Each code carries exactly one
    /// severity (`severity`), which is what makes the verdict a pure
    /// function of the reason set: verdict = max severity present, `proceed`
    /// when empty.
    public enum ReasonCode: String, Codable, Sendable, CaseIterable {
        /// Thermal pressure `critical` — the OS is already shedding load;
        /// adding more is counterproductive *and* recovery time is
        /// unpredictable, hence `do_not_start` rather than `wait`.
        case thermalCritical = "thermal_critical"
        /// Thermal pressure `serious`, active throttling, or SoC above
        /// `SystemAdvisor.highSoCTempCelsius` — recoverable by waiting,
        /// and the one case where `suggestedWaitSeconds` can be a real
        /// number (a cooling trend extrapolates; see
        /// `SystemAdvisor.cooldownETASeconds`).
        case thermalElevated = "thermal_elevated"
        /// CPU above `SystemAdvisor.highCPUPercent` — something is already
        /// using the machine; a new heavy workload will contend rather than
        /// fail, hence `wait` not `do_not_start`.
        case cpuSaturated = "cpu_saturated"
        /// On battery at or below `criticalBatteryPercent` — see that
        /// constant for why this is `do_not_start`.
        case onBatteryCritical = "on_battery_critical"
        /// On battery below `SystemAdvisor.lowBatteryPercent` — `wait`,
        /// but with `suggestedWaitSeconds` deliberately `nil`: time alone
        /// doesn't fix a discharging battery, plugging in does.
        case onBatteryLow = "on_battery_low"
        /// Memory pressure `critical` — the compressor/swap are already
        /// struggling; a new multi-hundred-MB agent process makes every
        /// running process slower, hence `do_not_start`.
        case memoryPressureCritical = "memory_pressure_critical"
        /// Memory pressure `warning` — headroom is thin but the machine is
        /// coping; `caution`, because a small job is still fine.
        case memoryPressure = "memory_pressure"
        /// Low Power Mode — everything runs, just slower; purely
        /// informational, hence `caution`.
        case lowPowerMode = "low_power_mode"
        /// At least one *other* MCP session has called tools recently (per
        /// `AgentSessionRegistry`). Advisory only — Sentry informs, it does
        /// not lock — and `caution` because two light sessions coexist
        /// fine; the message names the sessions so the caller can decide.
        /// Session labels are self-reported client names, not authenticated
        /// identities.
        case anotherAgentActive = "another_agent_active"

        /// The single severity this code contributes — see the type doc
        /// comment. An exhaustive switch, so adding a code without deciding
        /// its severity doesn't compile.
        public var severity: Verdict {
            switch self {
            case .thermalCritical, .onBatteryCritical, .memoryPressureCritical:
                return .doNotStart
            case .thermalElevated, .cpuSaturated, .onBatteryLow:
                return .wait
            case .memoryPressure, .lowPowerMode, .anotherAgentActive:
                return .caution
            }
        }
    }

    /// One `{code, message}` pair — the code for branching, the sentence for
    /// relaying to a human (or pasting into an agent's own status update).
    public struct Reason: Codable, Sendable, Equatable {
        public var code: ReasonCode
        public var message: String

        public init(code: ReasonCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    // MARK: - Result

    /// The compact numbers the verdict was computed from — returned so an
    /// agent never needs a follow-up `get_system_snapshot` just to log what
    /// it decided on, and so a "proceed" is auditable after the fact.
    public struct Snapshot: Codable, Sendable {
        public var cpuPercent: Double?
        /// `MemoryPressureLevel` as a string ("normal"/"warning"/"critical"),
        /// `nil` when the collector hasn't reported one.
        public var memoryPressure: String?
        public var thermalPressure: String
        public var socTemperatureCelsius: Double?
        public var isThrottling: Bool
        public var batteryChargePercent: Double?
        public var isPluggedIn: Bool?
        public var lowPowerModeEnabled: Bool
        /// Count of *other* active MCP sessions — self-reported labels, so
        /// two clients announcing the same name collapse into one.
        public var activeAgentSessionCount: Int
        public var timestamp: Date
    }

    public struct Assessment: Codable, Sendable {
        public var verdict: Verdict
        public var reasons: [Reason]
        /// Populated only when `verdict == .wait` *and* there is a
        /// defensible estimate (currently: a measurable cooling trend —
        /// `SystemAdvisor.cooldownETASeconds`). `nil` under a `wait`
        /// verdict means "no honest number; poll `wait_until_ready` with
        /// condition `ready` instead" — never "no wait needed".
        public var suggestedWaitSeconds: Double?
        public var snapshot: Snapshot
    }

    // MARK: - Policy

    /// The policy itself. Every input is explicit — nothing is read from
    /// `ProcessInfo`, a registry singleton, or a store — so tests can pin
    /// every boundary and `WaitCondition.ready` can evaluate the
    /// snapshot-only subset (see `isReady(_:)`).
    ///
    /// - Parameters:
    ///   - otherActiveAgentSessionCount: active `AgentSessionRegistry`
    ///     sessions *excluding the caller*; the caller's own session must
    ///     not make it warn about itself.
    ///   - otherActiveAgentLabels: names for the message (self-reported).
    ///   - recentSoCTemperatureSamples: recent `(timestamp, °C)` history for
    ///     the cooling-trend ETA — pass `[]` when history isn't cheaply at
    ///     hand; the only cost is a `nil` `suggestedWaitSeconds`.
    public static func assess(
        _ snapshot: SystemSnapshot,
        lowPowerModeEnabled: Bool,
        otherActiveAgentSessionCount: Int = 0,
        otherActiveAgentLabels: [String] = [],
        recentSoCTemperatureSamples: [(timestamp: Date, celsius: Double)] = []
    ) -> Assessment {
        var reasons: [Reason] = []

        // Thermal — critical pressure outranks (and subsumes) elevated, so
        // only one thermal reason is ever emitted.
        let thermal = snapshot.thermal
        let pressure = thermal?.pressureLevel ?? .nominal
        let socTemp = thermal?.socTemperatureCelsius
        let isThrottling = thermal?.isThrottling ?? false
        if pressure == .critical {
            reasons.append(Reason(
                code: .thermalCritical,
                message: "Thermal pressure is critical — the OS is already shedding load; don't start new work until it recovers."
            ))
        } else if pressure == .serious || isThrottling || (socTemp.map { $0 > SystemAdvisor.highSoCTempCelsius } ?? false) {
            var detail = "Thermal pressure is elevated"
            if isThrottling { detail += " and the machine is throttling" }
            if let socTemp, socTemp > SystemAdvisor.highSoCTempCelsius {
                // Display only — the gate on the `else if` above is the raw
                // Celsius comparison and is unaffected by the user's unit.
                let observed = TemperatureFormatter.string(celsius: socTemp, style: .whole)
                let limit = TemperatureFormatter.string(celsius: SystemAdvisor.highSoCTempCelsius, style: .whole)
                detail += " (SoC at \(observed), above \(limit))"
            }
            reasons.append(Reason(code: .thermalElevated, message: detail + " — waiting will help."))
        }

        // CPU.
        let cpuPercent = snapshot.cpu?.totalPercent
        if let cpuPercent, cpuPercent > SystemAdvisor.highCPUPercent {
            reasons.append(Reason(
                code: .cpuSaturated,
                message: "CPU is already at \(Int(cpuPercent))% — a new heavy workload will contend with whatever is running."
            ))
        }

        // Battery — critical outranks (and subsumes) low, same shape as
        // thermal above.
        let onBattery = snapshot.battery.map { !$0.isPluggedIn } ?? false
        let chargePercent = snapshot.battery?.chargePercent
        if onBattery, let chargePercent {
            if chargePercent <= criticalBatteryPercent {
                reasons.append(Reason(
                    code: .onBatteryCritical,
                    message: "On battery at \(Int(chargePercent))% — a heavy job risks dying mid-run; plug in before starting."
                ))
            } else if chargePercent < SystemAdvisor.lowBatteryPercent {
                reasons.append(Reason(
                    code: .onBatteryLow,
                    message: "On battery at \(Int(chargePercent))% — waiting won't recharge it; plug in, or keep the job small."
                ))
            }
        }

        // Memory pressure — critical outranks warning.
        switch snapshot.memory?.pressureLevel {
        case .critical:
            reasons.append(Reason(
                code: .memoryPressureCritical,
                message: "Memory pressure is critical — starting another process now will slow everything on this Mac."
            ))
        case .warning:
            reasons.append(Reason(
                code: .memoryPressure,
                message: "Memory pressure is elevated — headroom is thin for a large new workload."
            ))
        case .normal, nil:
            break
        }

        // Environment.
        if lowPowerModeEnabled {
            reasons.append(Reason(
                code: .lowPowerMode,
                message: "Low Power Mode is on — expect reduced performance."
            ))
        }
        if otherActiveAgentSessionCount > 0 {
            let labels = otherActiveAgentLabels.isEmpty
                ? ""
                : " (\(otherActiveAgentLabels.joined(separator: ", ")))"
            reasons.append(Reason(
                code: .anotherAgentActive,
                message: "\(otherActiveAgentSessionCount) other agent session(s) recently active\(labels) — check get_agent_capacity before starting heavy work. Session names are self-reported."
            ))
        }

        let verdict = reasons.reduce(Verdict.proceed) { $0.combined(with: $1.code.severity) }

        // A wait estimate only when the verdict is `wait` and the wait is
        // thermal with a measurable cooling trend — the one case a linear
        // fit has something honest to say. See `suggestedWaitSeconds`'s doc
        // comment for what `nil` means.
        var suggestedWait: Double?
        if verdict == .wait, reasons.contains(where: { $0.code == .thermalElevated }) {
            suggestedWait = SystemAdvisor.cooldownETASeconds(tempSamples: recentSoCTemperatureSamples)
        }

        return Assessment(
            verdict: verdict,
            reasons: reasons,
            suggestedWaitSeconds: suggestedWait,
            snapshot: Snapshot(
                cpuPercent: cpuPercent,
                memoryPressure: snapshot.memory?.pressureLevel.map(Self.pressureName),
                thermalPressure: pressure.rawValue,
                socTemperatureCelsius: socTemp,
                isThrottling: isThrottling,
                batteryChargePercent: chargePercent,
                isPluggedIn: snapshot.battery?.isPluggedIn,
                lowPowerModeEnabled: lowPowerModeEnabled,
                activeAgentSessionCount: otherActiveAgentSessionCount,
                timestamp: snapshot.timestamp
            )
        )
    }

    /// The snapshot-only readiness gate `WaitCondition.ready` polls — the
    /// two tools' shared contract, reduced to what a bare snapshot can
    /// answer. Ready ⇔ the verdict is below `wait`. The inputs a snapshot
    /// doesn't carry (Low Power Mode, other sessions) are deliberately
    /// zeroed rather than plumbed in: both cap out at `caution`, which
    /// never blocks, so omitting them cannot make this disagree with
    /// `preflight_check` about whether to stop waiting —
    /// `AgentPreflightTests` pins that equivalence.
    public static func isReady(_ snapshot: SystemSnapshot) -> Bool {
        let verdict = assess(snapshot, lowPowerModeEnabled: false).verdict
        return verdict.rank < Verdict.wait.rank
    }

    /// `MemoryPressureLevel` is an `Int`-raw-valued enum (its raw values are
    /// the kernel's dispatch-source flags), so the wire string is named
    /// here rather than leaking `1/2/4` to agents.
    private static func pressureName(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}
