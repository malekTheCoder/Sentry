import Foundation

/// One interval during which a keep-awake assertion was held, tagged with
/// the session that requested it. Appended by `PowerControlService`
/// (`SentryKit/Services/PowerControlService.swift`) whenever an assertion
/// starts/stops; consumed by `AgentSessionReport.awakeSeconds` to answer
/// "how long did *this* session hold the machine awake."
///
/// In-memory only, deliberately: assertion state itself doesn't survive the
/// process (powerd drops assertions when the owner dies — see
/// `PowerControlService.reconcilePersistedState`), so a durable ledger
/// would claim precision about past runs the underlying mechanism can't
/// back up.
public struct AgentAwakeHold: Equatable, Sendable {
    /// Session ID of the requester (see `AgentSessionIdentity`), or `nil`
    /// for holds started by the user through the UI / non-agent paths.
    public let owner: String?
    public let start: Date
    /// `nil` while the hold is still open — `AgentSessionReport` clamps an
    /// open hold to the query window's end rather than guessing a future
    /// release time.
    public let end: Date?

    public init(owner: String?, start: Date, end: Date?) {
        self.owner = owner
        self.start = start
        self.end = end
    }
}

/// Per-session rollup of `agent_activity_log` events for UI presentation —
/// the Dashboard's `AgentActivityCard` renders one row per value. Built by
/// `AgentSessionReport.sessions(from:awakeHolds:)`.
public struct AgentSessionSummary: Equatable, Sendable, Identifiable {
    /// The session ID, or a `"legacy:"`-prefixed client name for pre-v5
    /// rows that carry no session — see `sessions(from:awakeHolds:)`.
    public let id: String
    public let clientName: String
    public let start: Date
    public let end: Date
    /// Every attempted call in the session, including denied ones — the
    /// activity card is an audit view, not a success counter.
    public let callCount: Int
    public let toolCallCounts: [String: Int]
    public let awakeSecondsHeld: Double

    public init(id: String, clientName: String, start: Date, end: Date, callCount: Int, toolCallCounts: [String: Int], awakeSecondsHeld: Double) {
        self.id = id
        self.clientName = clientName
        self.start = start
        self.end = end
        self.callCount = callCount
        self.toolCallCounts = toolCallCounts
        self.awakeSecondsHeld = awakeSecondsHeld
    }
}

/// Full attribution for one session over a query window — what
/// `get_session_resource_report` returns (see
/// `MCPPayloads.SessionResourceReport`'s session fields).
public struct AgentSessionAttribution: Equatable, Sendable {
    public let sessionID: String
    public let clientName: String
    /// First/last logged call in the window; `nil` when the session made no
    /// calls inside it.
    public let sessionStart: Date?
    public let sessionEnd: Date?
    public let callCount: Int
    public let toolCallCounts: [String: Int]
    public let keepAwakeSecondsHeld: Double
    /// Battery percentage points the machine lost between the first and
    /// last battery sample in the window (negative when it charged).
    /// **Machine-wide, not attributable solely to the agent** — everything
    /// else running on the Mac drained the same battery, so read this as
    /// "drained *during* this session," never "caused *by* it." `nil` when
    /// fewer than two battery samples exist in the window.
    public let batteryPercentDrained: Double?
    /// Whether any thermal-pressure sample in the window was above nominal
    /// (`thermal.pressure_level` > 0 — fair, serious, or critical), and for
    /// approximately how long. Same machine-wide caveat as battery drain.
    public let thermalPressureElevated: Bool
    public let thermalPressureElevatedSeconds: Double
    /// Whether a `caffeinate` process this session's client plausibly
    /// spawned (best-effort match — see `CaffeinateArbitrator
    /// .matchExternalCaffeinates(in:)`) was detected holding this Mac awake
    /// independently of Sentry's own `keep_awake` tool, and its raw argv if
    /// so. Additive fields (agent-guardrail arbitration pass): both default
    /// to "not detected" so every existing caller of the memberwise `init`
    /// or `attribution(...)` factory below keeps compiling and reporting
    /// exactly what it always has, unless it explicitly opts into passing
    /// `CaffeinateArbitrator` results through. `nil`/`false` here says
    /// nothing about whether one actually exists — only whether this
    /// report was ever handed the data to know.
    public let externalCaffeinateDetected: Bool
    public let externalCaffeinateArguments: [String]?

    public init(
        sessionID: String,
        clientName: String,
        sessionStart: Date?,
        sessionEnd: Date?,
        callCount: Int,
        toolCallCounts: [String: Int],
        keepAwakeSecondsHeld: Double,
        batteryPercentDrained: Double?,
        thermalPressureElevated: Bool,
        thermalPressureElevatedSeconds: Double,
        externalCaffeinateDetected: Bool = false,
        externalCaffeinateArguments: [String]? = nil
    ) {
        self.sessionID = sessionID
        self.clientName = clientName
        self.sessionStart = sessionStart
        self.sessionEnd = sessionEnd
        self.callCount = callCount
        self.toolCallCounts = toolCallCounts
        self.keepAwakeSecondsHeld = keepAwakeSecondsHeld
        self.batteryPercentDrained = batteryPercentDrained
        self.thermalPressureElevated = thermalPressureElevated
        self.thermalPressureElevatedSeconds = thermalPressureElevatedSeconds
        self.externalCaffeinateDetected = externalCaffeinateDetected
        self.externalCaffeinateArguments = externalCaffeinateArguments
    }
}

/// Pure attribution arithmetic for agent sessions (agent-session
/// attribution pass): correlates `agent_activity_log` events
/// (`HistoryStore.agentActivityEvents`), the keep-awake ledger
/// (`PowerControlService.awakeHolds`), and already-persisted metric history
/// (`HistoryStore.samples`) into per-session summaries. Every function is
/// static and side-effect free — same "independently testable without a
/// real store" reasoning as `DashboardViewModel.downsample`.
public enum AgentSessionReport {

    /// A sample's assumed coverage is the gap back to the previous sample,
    /// capped so one stale/late sample can't inflate a duration total — the
    /// same bound `MCPXPCService`'s `secondsThrottling` estimate uses.
    static let maxSampleGapSeconds: Double = 300

    // MARK: - Keep-awake attribution

    /// Total seconds within `window` during which a hold owned by
    /// `owner` was live. Open-ended holds (`end == nil`) are clamped to
    /// `window.upperBound` — the hold demonstrably ran at least that long,
    /// and guessing beyond the window would be fabrication.
    public static func awakeSeconds(
        holds: [AgentAwakeHold],
        owner: String?,
        window: ClosedRange<Date>
    ) -> Double {
        holds.reduce(0) { total, hold in
            guard hold.owner == owner else { return total }
            let start = max(hold.start, window.lowerBound)
            let end = min(hold.end ?? window.upperBound, window.upperBound)
            return total + max(0, end.timeIntervalSince(start))
        }
    }

    // MARK: - Machine-wide window facts

    /// First-minus-last battery charge over the window: positive = net
    /// drain, negative = net charge. See
    /// `AgentSessionAttribution.batteryPercentDrained` for why this is a
    /// machine-wide "during," never an agent-caused "because."
    public static func batteryPercentDrained(
        samples: [(timestamp: Date, value: Double)]
    ) -> Double? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return nil }
        return first.value - last.value
    }

    /// Approximate seconds the thermal pressure level sat above nominal
    /// (`thermal.pressure_level` samples with value > 0), accumulated by
    /// assuming each sample covers the (capped) interval since the previous
    /// one — a best-effort estimate over already-persisted samples, not a
    /// continuous measurement.
    public static func thermalElevation(
        samples: [(timestamp: Date, value: Double)],
        windowStart: Date
    ) -> (elevated: Bool, seconds: Double) {
        var seconds: Double = 0
        var elevated = false
        var previous = windowStart
        for sample in samples {
            let interval = min(sample.timestamp.timeIntervalSince(previous), maxSampleGapSeconds)
            if sample.value > 0 {
                elevated = true
                seconds += max(0, interval)
            }
            previous = sample.timestamp
        }
        return (elevated, seconds)
    }

    // MARK: - Full attribution

    /// Correlates one session's events with the awake ledger and
    /// battery/thermal history into the shape
    /// `get_session_resource_report` returns. `events` should already be
    /// scoped to the session (or, as a fallback, to the client name —
    /// `MCPXPCService.getSessionResourceReport` decides that scoping).
    /// - Parameter externalCaffeinateMatches: Claude-spawned `caffeinate`
    ///   processes already correlated to this session's client name (see
    ///   `CaffeinateArbitrator.attribute(matches:sessions:)`), or `nil` when
    ///   the caller hasn't wired that detection in — the default, so every
    ///   existing call site of this method is unaffected. When non-empty,
    ///   the first match's argv is what's surfaced (`AgentSessionAttribution
    ///   .externalCaffeinateArguments`) — one representative invocation is
    ///   enough to make the report's claim legible; this report's job is
    ///   attribution, not a live process inventory.
    public static func attribution(
        sessionID: String,
        clientName: String,
        events: [AgentActivityEvent],
        awakeHolds: [AgentAwakeHold],
        batterySamples: [(timestamp: Date, value: Double)],
        thermalPressureSamples: [(timestamp: Date, value: Double)],
        window: ClosedRange<Date>,
        externalCaffeinateMatches: [CaffeinateArbitrator.ExternalCaffeinateMatch]? = nil
    ) -> AgentSessionAttribution {
        var toolCounts: [String: Int] = [:]
        for event in events {
            toolCounts[event.tool, default: 0] += 1
        }
        let thermal = thermalElevation(samples: thermalPressureSamples, windowStart: window.lowerBound)
        let matches = externalCaffeinateMatches ?? []
        return AgentSessionAttribution(
            sessionID: sessionID,
            clientName: clientName,
            sessionStart: events.map(\.timestamp).min(),
            sessionEnd: events.map(\.timestamp).max(),
            callCount: events.count,
            toolCallCounts: toolCounts,
            keepAwakeSecondsHeld: awakeSeconds(holds: awakeHolds, owner: sessionID, window: window),
            batteryPercentDrained: batteryPercentDrained(samples: batterySamples),
            thermalPressureElevated: thermal.elevated,
            thermalPressureElevatedSeconds: thermal.seconds,
            externalCaffeinateDetected: !matches.isEmpty,
            externalCaffeinateArguments: matches.first?.arguments
        )
    }

    // MARK: - Dashboard grouping

    /// Prefix for the synthetic group key given to pre-v5 events that carry
    /// no session ID — grouped by client name instead, so old history still
    /// renders as *something* coherent rather than one giant "unknown" row.
    public static let legacyGroupPrefix = "legacy:"

    /// Groups a window's events into per-session summaries, most recent
    /// last-activity first — the Dashboard `AgentActivityCard`'s data
    /// source. Awake time per session comes from the in-memory ledger, so
    /// it only covers holds from the current app run (see
    /// `AgentAwakeHold`'s doc comment); sessions older than the current run
    /// honestly show zero rather than a reconstructed guess.
    public static func sessions(
        from events: [AgentActivityEvent],
        awakeHolds: [AgentAwakeHold],
        now: Date = Date()
    ) -> [AgentSessionSummary] {
        var grouped: [String: [AgentActivityEvent]] = [:]
        for event in events {
            let key = event.sessionID.isEmpty ? legacyGroupPrefix + event.clientName : event.sessionID
            grouped[key, default: []].append(event)
        }

        return grouped.compactMap { key, sessionEvents -> AgentSessionSummary? in
            guard
                let start = sessionEvents.map(\.timestamp).min(),
                let end = sessionEvents.map(\.timestamp).max()
            else { return nil }
            var toolCounts: [String: Int] = [:]
            for event in sessionEvents {
                toolCounts[event.tool, default: 0] += 1
            }
            let awake = key.hasPrefix(legacyGroupPrefix)
                ? 0
                : awakeSeconds(holds: awakeHolds, owner: key, window: start...max(now, end))
            return AgentSessionSummary(
                id: key,
                clientName: sessionEvents.first?.clientName ?? "",
                start: start,
                end: end,
                callCount: sessionEvents.count,
                toolCallCounts: toolCounts,
                awakeSecondsHeld: awake
            )
        }
        .sorted { $0.end > $1.end }
    }
}
