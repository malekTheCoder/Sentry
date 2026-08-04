import Foundation

// MARK: - AgentGuardrailSettings: the user's conditional-guardrail policy set

/// Everything the user can configure about agent guardrails and termination
/// controls, persisted as one nested `"agentGuardrails": { … }` block in
/// `AppSettings` (`SentryKit/Settings/AppSettings.swift`) — the same
/// one-additive-key shape `FanControlSettings` established, so `settings.json`
/// grows a single readable object and `AppSettings.init(from:)` gains exactly
/// one new key to defend.
///
/// **These are policies, not enforcement.** Enforcement happens in exactly two
/// places, both of which read this struct fresh on every decision:
/// `MCPXPCService.authorize` (`Sentry/App/MCPXPCService.swift`) evaluates
/// `AgentGuardrails.evaluate` before any tool call executes, and
/// `AppDelegate`'s snapshot loop evaluates
/// `AgentGuardrails.autoRevocationReason` to release an agent-held keep-awake
/// assertion when a condition arises mid-hold (quiet hours starting, thermal
/// pressure climbing, the kill switch engaging).
///
/// **Trust note on `revokedClientNames`.** MCP client names are self-reported
/// by the connecting process over stdio/HTTP — a label, not a verified
/// identity (only the XPC bridge path, `MCPBridgePeerGate`, verifies the peer
/// *process*, and even that says nothing about which "client" the process
/// claims to be). Per-agent revocation is therefore best-effort labeling: it
/// reliably stops a well-behaved client, and a hostile local process could
/// simply present a different name. The kill switch (`killSwitchEngaged`)
/// exists precisely because it has no such hole — it denies every call
/// regardless of what the caller calls itself. The AI Access pane's copy says
/// the same thing to the user.
public struct AgentGuardrailSettings: Codable, Equatable, Sendable {

    // MARK: Kill switch + per-agent stop

    /// The global kill switch: while `true`, every MCP tool call — read and
    /// write, from every client — is denied at `MCPXPCService.authorize`,
    /// and any agent-held keep-awake assertion is released the moment it
    /// engages (see `AppDelegate.applySettings`' rising-edge handling).
    /// Persisted deliberately: a user who paused agent access and then
    /// relaunched Sentry has not thereby un-paused it.
    public var killSwitchEngaged: Bool

    /// Client names whose calls are denied until the user re-enables them
    /// (AI Access pane, Guardrails section). See the type doc comment for
    /// why this is a best-effort label check, not a security boundary.
    public var revokedClientNames: Set<String>

    // MARK: Battery floor

    /// When on, `keep_awake` (and, with `batteryFloorAppliesToAllWriteTools`,
    /// every write tool) is denied while the battery is strictly below
    /// `batteryFloorPercent` and the Mac is not plugged in. On by default:
    /// an agent holding a nearly-dead laptop awake is the single failure
    /// mode this feature set most obviously exists to prevent, and the
    /// plugged-in override means the default costs a desk-bound Mac nothing.
    public var batteryFloorEnabled: Bool

    /// The floor, in percent. "Below" is strict — a battery at exactly the
    /// floor passes, matching the wording every surface uses ("below N%").
    public var batteryFloorPercent: Double

    /// Widens the battery floor from `keep_awake` alone to every write tool.
    /// Off by default: `set_alert_rule_enabled` at 15% battery is harmless,
    /// and denying it would be guardrail theater.
    public var batteryFloorAppliesToAllWriteTools: Bool

    // MARK: On-battery restriction

    /// When on, every write tool is denied while the Mac reports it is not
    /// plugged in — a coarser sibling of the battery floor for users who
    /// want agents to be strictly read-only away from power. Off by default.
    public var denyWriteToolsOnBattery: Bool

    // MARK: Quiet hours

    /// When on, no agent may hold keep-awake during the
    /// `quietHoursStartMinute`..`quietHoursEndMinute` window: new
    /// `keep_awake` calls are denied, and an assertion an agent already
    /// holds is released when the window starts (the auto-revoke path).
    /// Off by default — a time window is a preference, not a protection
    /// every user wants.
    public var quietHoursEnabled: Bool

    /// Window start, in minutes after local midnight (0...1439). Minutes
    /// rather than a `Date` because a daily window has no date component to
    /// store, and minutes-after-midnight round-trips through JSON without a
    /// timezone to get wrong. Default 22:00.
    public var quietHoursStartMinute: Int

    /// Window end, same encoding. May be *earlier* than the start, which
    /// means the window crosses midnight (22:00–07:00) — see
    /// `AgentGuardrails.isWithinQuietHours`. Start == end means a
    /// zero-length window, i.e. never active, rather than "all day":
    /// a degenerate configuration should fail toward doing nothing.
    /// Default 07:00.
    public var quietHoursEndMinute: Int

    // MARK: Thermal auto-revoke

    /// When on, agent-held keep-awake assertions are auto-released while
    /// thermal pressure is `serious` or `critical`, and new `keep_awake`
    /// calls are denied until pressure drops back below `serious`. On by
    /// default for the same reasoning as the battery floor: an agent pinning
    /// a throttling Mac awake makes the thermal problem strictly worse.
    public var thermalAutoRevokeEnabled: Bool

    // MARK: External sleep-inhibitor enforcement (see CaffeinateArbitrator)

    /// When on, and only while an `AgentGuardrails.autoRevocationReason`
    /// condition is active (battery critical, quiet hours, thermal serious+
    /// — i.e. the exact moment Sentry would already be releasing its own
    /// agent-held `keep_awake`), Sentry also terminates any `caffeinate`
    /// process it detects was spawned by a Claude Code session
    /// (`CaffeinateArbitrator.enforce(settings:context:sessions:)`).
    ///
    /// **This deserves honest copy, not a euphemism, because of what it
    /// actually does: it calls `kill()` on a process Sentry does not own.**
    /// Claude Code spawns `caffeinate -i -t 300` on its own, respawning it
    /// every ~300 seconds, with no user-facing setting on Claude's side to
    /// disable it (documented, unresolved, on Anthropic's own issue
    /// tracker as of this writing) — it is invisible to, and unaffected by,
    /// every other guardrail in this file, because those only ever govern
    /// Sentry's *own* `keep_awake` MCP tool via `PowerControlService`. This
    /// is the one guardrail that reaches outside that boundary. On by
    /// default for the same reasoning `batteryFloorEnabled` and
    /// `thermalAutoRevokeEnabled` already use here: a coding agent's
    /// sleep-inhibitor left running on a critically low battery is
    /// precisely the failure mode this feature set exists to prevent, and
    /// it fires only in the narrow window where Sentry has independently
    /// decided this Mac should not be held awake right now. A user who
    /// doesn't want Sentry killing a process it doesn't own — even in that
    /// narrow window — can turn this off; the rest of the guardrails above
    /// are unaffected either way.
    public var enforceAgainstExternalCaffeinate: Bool

    private enum CodingKeys: String, CodingKey {
        case killSwitchEngaged
        case revokedClientNames
        case batteryFloorEnabled
        case batteryFloorPercent
        case batteryFloorAppliesToAllWriteTools
        case denyWriteToolsOnBattery
        case quietHoursEnabled
        case quietHoursStartMinute
        case quietHoursEndMinute
        case thermalAutoRevokeEnabled
        case enforceAgainstExternalCaffeinate
    }

    public init(
        killSwitchEngaged: Bool = false,
        revokedClientNames: Set<String> = [],
        batteryFloorEnabled: Bool = true,
        batteryFloorPercent: Double = 20,
        batteryFloorAppliesToAllWriteTools: Bool = false,
        denyWriteToolsOnBattery: Bool = false,
        quietHoursEnabled: Bool = false,
        quietHoursStartMinute: Int = 22 * 60,
        quietHoursEndMinute: Int = 7 * 60,
        thermalAutoRevokeEnabled: Bool = true,
        enforceAgainstExternalCaffeinate: Bool = true
    ) {
        self.killSwitchEngaged = killSwitchEngaged
        self.revokedClientNames = revokedClientNames
        self.batteryFloorEnabled = batteryFloorEnabled
        self.batteryFloorPercent = batteryFloorPercent
        self.batteryFloorAppliesToAllWriteTools = batteryFloorAppliesToAllWriteTools
        self.denyWriteToolsOnBattery = denyWriteToolsOnBattery
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursEndMinute = quietHoursEndMinute
        self.quietHoursStartMinute = quietHoursStartMinute
        self.thermalAutoRevokeEnabled = thermalAutoRevokeEnabled
        self.enforceAgainstExternalCaffeinate = enforceAgainstExternalCaffeinate
    }

    /// Same additive-`Codable` discipline as `FanControlSettings.init(from:)`
    /// and `AppSettings.init(from:)`: every key optional, every absence
    /// falling back to the shipped default, so a `settings.json` written
    /// before a future guardrail existed still decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AgentGuardrailSettings()
        self.init(
            killSwitchEngaged: try container.decodeIfPresent(Bool.self, forKey: .killSwitchEngaged)
                ?? fallback.killSwitchEngaged,
            revokedClientNames: try container.decodeIfPresent(Set<String>.self, forKey: .revokedClientNames)
                ?? fallback.revokedClientNames,
            batteryFloorEnabled: try container.decodeIfPresent(Bool.self, forKey: .batteryFloorEnabled)
                ?? fallback.batteryFloorEnabled,
            batteryFloorPercent: try container.decodeIfPresent(Double.self, forKey: .batteryFloorPercent)
                ?? fallback.batteryFloorPercent,
            batteryFloorAppliesToAllWriteTools: try container.decodeIfPresent(Bool.self, forKey: .batteryFloorAppliesToAllWriteTools)
                ?? fallback.batteryFloorAppliesToAllWriteTools,
            denyWriteToolsOnBattery: try container.decodeIfPresent(Bool.self, forKey: .denyWriteToolsOnBattery)
                ?? fallback.denyWriteToolsOnBattery,
            quietHoursEnabled: try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled)
                ?? fallback.quietHoursEnabled,
            quietHoursStartMinute: try container.decodeIfPresent(Int.self, forKey: .quietHoursStartMinute)
                ?? fallback.quietHoursStartMinute,
            quietHoursEndMinute: try container.decodeIfPresent(Int.self, forKey: .quietHoursEndMinute)
                ?? fallback.quietHoursEndMinute,
            thermalAutoRevokeEnabled: try container.decodeIfPresent(Bool.self, forKey: .thermalAutoRevokeEnabled)
                ?? fallback.thermalAutoRevokeEnabled,
            enforceAgainstExternalCaffeinate: try container.decodeIfPresent(Bool.self, forKey: .enforceAgainstExternalCaffeinate)
                ?? fallback.enforceAgainstExternalCaffeinate
        )
    }
}

// MARK: - AgentGuardrails: the pure policy engine

/// Pure verdict logic for the conditional guardrails and termination
/// controls: a function of (policy settings, power/thermal state, clock) →
/// verdict, with no service references, no timers, and no I/O — the same
/// testing posture as `MCPAccessController.evaluate` and `LocalSyncFraming`.
///
/// Two entry points, matching the two moments a guardrail can act:
///
/// - `evaluate(tool:clientName:settings:context:)` — the *gate*, run by
///   `MCPXPCService.authorize` on every tool call before execution. Denies
///   with a structured, honest sentence the calling agent sees verbatim.
/// - `autoRevocationReason(settings:context:)` — the *revoker*, run by
///   `AppDelegate`'s snapshot loop against a currently agent-held keep-awake
///   assertion (`PowerControlService.agentAssertionOwner`). Returns the
///   reason an existing hold should be released now, or `nil`.
///
/// Deliberately an caseless `enum` namespace, not a class: there is no state
/// to hold — the rate limiter's statefulness is what forced
/// `MCPAccessController` to be a class, and nothing here has that problem.
public enum AgentGuardrails {

    /// The power/thermal facts a verdict is computed from, captured at the
    /// call site (from `StatsCoordinator.latestSnapshot()`) rather than read
    /// inside the engine, so tests can fabricate any machine state.
    ///
    /// Every reading is Optional for the usual P5 reason: a desktop Mac has
    /// no battery, and a snapshot taken before the first thermal sample has
    /// no pressure reading. **Absence never denies** — `isPluggedIn == nil`
    /// is treated as "not known to be on battery," not as "on battery,"
    /// because a guardrail that fires on missing data would deny every write
    /// tool on every Mac mini forever.
    public struct PowerContext: Equatable, Sendable {
        public var batteryPercent: Double?
        public var isPluggedIn: Bool?
        public var thermalPressure: ThermalStats.PressureLevel?
        public var date: Date
        /// Injectable so quiet-hours tests can pin a timezone instead of
        /// inheriting the build machine's.
        public var calendar: Calendar

        public init(
            batteryPercent: Double? = nil,
            isPluggedIn: Bool? = nil,
            thermalPressure: ThermalStats.PressureLevel? = nil,
            date: Date = Date(),
            calendar: Calendar = .current
        ) {
            self.batteryPercent = batteryPercent
            self.isPluggedIn = isPluggedIn
            self.thermalPressure = thermalPressure
            self.date = date
            self.calendar = calendar
        }

        /// The one production construction path, so `MCPXPCService` and
        /// `AppDelegate` cannot drift on which snapshot fields feed which
        /// policy.
        public static func from(
            snapshot: SystemSnapshot,
            date: Date = Date(),
            calendar: Calendar = .current
        ) -> PowerContext {
            PowerContext(
                batteryPercent: snapshot.battery?.chargePercent,
                isPluggedIn: snapshot.battery?.isPluggedIn,
                thermalPressure: snapshot.thermal?.pressureLevel,
                date: date,
                calendar: calendar
            )
        }
    }

    public enum Verdict: Equatable, Sendable {
        case allow
        /// `reason` is the full user/agent-facing sentence — `MCPXPCService`
        /// returns it verbatim through the tool call's error channel, so it
        /// is written to be read by the agent that was denied ("Sentry
        /// declined this: …"), never as an internal code.
        case deny(reason: String)
    }

    /// The gate. Checked in a fixed order so the reason an agent sees is
    /// the broadest one that applies: kill switch → per-client revocation →
    /// on-battery restriction → battery floor → quiet hours → thermal.
    /// Read tools pass everything except the kill switch and per-client
    /// revocation — the conditional policies are write-tool concerns by
    /// definition.
    public static func evaluate(
        tool: MCPToolID,
        clientName: String,
        settings: AgentGuardrailSettings,
        context: PowerContext
    ) -> Verdict {
        if settings.killSwitchEngaged {
            return .deny(reason: String(localized: "Sentry declined this: agent access is paused by the kill switch. Resume it from Sentry's menu bar or Settings → AI Access."))
        }
        if settings.revokedClientNames.contains(clientName) {
            return .deny(reason: String(localized: "Sentry declined this: the user stopped agent access for \"\(clientName)\". It can be re-enabled in Settings → AI Access."))
        }

        guard tool.isWrite else { return .allow }

        if settings.denyWriteToolsOnBattery, context.isPluggedIn == false {
            return .deny(reason: String(localized: "Sentry declined this: this Mac is on battery power and write tools are disabled on battery."))
        }

        if settings.batteryFloorEnabled,
           tool == .keepAwake || settings.batteryFloorAppliesToAllWriteTools,
           context.isPluggedIn == false,
           let percent = context.batteryPercent,
           percent < settings.batteryFloorPercent {
            let observed = Int(percent.rounded())
            let floor = Int(settings.batteryFloorPercent.rounded())
            return .deny(reason: String(localized: "Sentry declined this: battery is at \(observed)% and unplugged (below the \(floor)% guardrail floor)."))
        }

        if settings.quietHoursEnabled,
           tool == .keepAwake,
           isWithinQuietHours(
               startMinute: settings.quietHoursStartMinute,
               endMinute: settings.quietHoursEndMinute,
               date: context.date,
               calendar: context.calendar
           ) {
            return .deny(reason: String(localized: "Sentry declined this: quiet hours (\(formattedMinute(settings.quietHoursStartMinute))–\(formattedMinute(settings.quietHoursEndMinute))) are in effect — agents may not keep this Mac awake right now."))
        }

        if settings.thermalAutoRevokeEnabled,
           tool == .keepAwake,
           let pressure = context.thermalPressure,
           pressure == .serious || pressure == .critical {
            return .deny(reason: String(localized: "Sentry declined this: thermal pressure is \(pressure.rawValue) — keep-awake requests are blocked until this Mac cools down."))
        }

        return .allow
    }

    /// The revoker: why an *existing* agent-held keep-awake assertion should
    /// be released right now, or `nil` if it may stand. Evaluated once per
    /// snapshot tick by `AppDelegate` against
    /// `PowerControlService.agentAssertionOwner` — since a release clears
    /// the owner, a revocation fires exactly once per hold rather than once
    /// per tick, with no debounce state needed here.
    ///
    /// Includes the kill switch even though `AppDelegate.applySettings`
    /// already releases on its rising edge: this makes the snapshot loop
    /// self-healing for a `killSwitchEngaged` that arrived without a
    /// settings emission (a hand-edited settings file read at launch).
    public static func autoRevocationReason(
        settings: AgentGuardrailSettings,
        context: PowerContext
    ) -> String? {
        if settings.killSwitchEngaged {
            return String(localized: "Agent access is paused — Sentry released the keep-awake hold an agent was holding.")
        }
        if settings.quietHoursEnabled,
           isWithinQuietHours(
               startMinute: settings.quietHoursStartMinute,
               endMinute: settings.quietHoursEndMinute,
               date: context.date,
               calendar: context.calendar
           ) {
            return String(localized: "Quiet hours started — Sentry released the keep-awake hold an agent was holding.")
        }
        if settings.thermalAutoRevokeEnabled,
           let pressure = context.thermalPressure,
           pressure == .serious || pressure == .critical {
            return String(localized: "Thermal pressure reached \(pressure.rawValue) — Sentry released the keep-awake hold an agent was holding.")
        }
        return nil
    }

    /// Whether `date` falls inside a daily minutes-after-midnight window,
    /// including windows that cross midnight (start > end, e.g. 22:00–07:00).
    /// Half-open on the end (`[start, end)`) so 07:00 exactly is *outside*
    /// a window ending at 07:00 — the first minute agents may hold awake
    /// again. `start == end` is a zero-length window: never inside.
    public static func isWithinQuietHours(
        startMinute: Int,
        endMinute: Int,
        date: Date,
        calendar: Calendar
    ) -> Bool {
        guard startMinute != endMinute else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        // Crosses midnight: inside means after the start *or* before the end.
        return minute >= startMinute || minute < endMinute
    }

    /// "22:00", "07:30" — a fixed 24-hour rendering for denial sentences.
    /// Not locale-formatted on purpose: this string travels to an MCP agent
    /// over a wire protocol, where an unambiguous 24-hour clock beats a
    /// locale guess made on the agent's behalf.
    public static func formattedMinute(_ minute: Int) -> String {
        let clamped = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
