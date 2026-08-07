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
///
/// **Why this type grew (agent-activity legibility pass).** Every field
/// added below was *already sitting in `agent_activity_log`* — the v5
/// migration has persisted `outcome`, `duration_ms` and `args_summary` per
/// row since the attribution pass — and `sessions(from:awakeHolds:)` was
/// throwing all of it away, collapsing a session to "N calls over M
/// minutes." That is the least interesting projection of the data: a
/// *denied* call is the one an operator actually needs to see (it means a
/// guardrail fired, or the rate limiter did, or the user said no), and
/// "which tool, how long ago" is what turns a row from a tally into a
/// description of what an agent is doing to this Mac right now. None of
/// this is new collection; it is the same query, projected honestly.
///
/// **Deliberately not a dictionary of outcome → count.** Three named
/// integers make the "did anything get refused" question a property access
/// at every call site (view, accessibility label, test) instead of a
/// dictionary lookup that silently reads `nil` as zero — and this codebase's
/// hard rule is that a missing reading must never render as a zero. Here the
/// counts are always genuinely computed from the events, so zero always
/// means zero.
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

    /// Raw tool name (`MCPToolID.rawValue`) of the most recent call in this
    /// session, paired with `end` as "when." `nil` only when a caller
    /// constructs a summary with no event behind it — `sessions(from:…)`
    /// always fills it, because a group cannot exist without at least one
    /// event. Optional rather than `""` so "not reported" stays
    /// representable and can never be mistaken for a tool actually named
    /// the empty string.
    public let lastTool: String?

    /// How that most recent call ended. Same honest-`nil` contract as
    /// `lastTool`: never defaulted to `.succeeded`, because "we don't know"
    /// and "it worked" are different claims and only one of them is safe to
    /// put in front of a user.
    public let lastOutcome: AgentActivityOutcome?

    /// Calls refused by the permission model, a guardrail, or a declined
    /// confirmation dialog (`AgentActivityOutcome.denied`).
    public let deniedCount: Int

    /// Calls refused specifically by the per-client rate limiter
    /// (`MCPAccessController.isRateLimited`). Kept separate from
    /// `deniedCount` for exactly the reason `AgentActivityOutcome` splits
    /// them: "you're calling too fast" and "you're not allowed" are
    /// different findings, and conflating them would hide a misbehaving
    /// agent behind a policy denial (or vice versa).
    public let rateLimitedCount: Int

    /// Calls that were authorized and ran, but whose reply carried an error.
    /// Counted, not surfaced as a denial: the agent was allowed to do this,
    /// it just didn't work.
    public let erroredCount: Int

    /// Whether this session owns a keep-awake hold that is **still open**
    /// (`AgentAwakeHold.end == nil`) — i.e. this agent is holding the Mac
    /// awake at this instant. Derived from the same ledger
    /// `awakeSecondsHeld` sums, so it costs nothing extra and cannot drift
    /// from it.
    ///
    /// This is the single most consequential thing an agent does, because it
    /// is the only one with a *physical* effect the user will notice (a
    /// laptop that won't sleep in a bag), which is why it gets its own flag
    /// rather than being inferred from "awakeSecondsHeld is large."
    /// Always `false` for legacy (pre-v5, session-less) groups — the ledger
    /// is keyed by session ID, and a client *name* must never match an owner
    /// slot by coincidence.
    public let holdsKeepAwakeNow: Bool

    /// Calls that never executed. The number a person scanning for trouble
    /// wants; `callCount` alone cannot distinguish a busy agent from a
    /// blocked one.
    public var blockedCount: Int { deniedCount + rateLimitedCount }

    /// Calls that executed and replied successfully. Derived rather than
    /// stored so it can never disagree with the parts it's made of.
    public var succeededCount: Int {
        max(0, callCount - deniedCount - rateLimitedCount - erroredCount)
    }

    /// Whether the session's last call is recent enough that Sentry would
    /// still consider it connected — see `AgentSessionReport.activeWithin`
    /// for why this is the registry's own definition rather than a second
    /// one invented here.
    public func isActive(asOf now: Date) -> Bool {
        now.timeIntervalSince(end) <= AgentSessionReport.activeWithin
    }

    /// New fields default to their "not reported" / "nothing refused"
    /// values so every pre-existing call site of this memberwise
    /// initializer keeps compiling and keeps meaning exactly what it did —
    /// the same additive discipline `AgentSessionAttribution.init` documents
    /// for its own late-added caffeinate fields.
    public init(
        id: String,
        clientName: String,
        start: Date,
        end: Date,
        callCount: Int,
        toolCallCounts: [String: Int],
        awakeSecondsHeld: Double,
        lastTool: String? = nil,
        lastOutcome: AgentActivityOutcome? = nil,
        deniedCount: Int = 0,
        rateLimitedCount: Int = 0,
        erroredCount: Int = 0,
        holdsKeepAwakeNow: Bool = false
    ) {
        self.id = id
        self.clientName = clientName
        self.start = start
        self.end = end
        self.callCount = callCount
        self.toolCallCounts = toolCallCounts
        self.awakeSecondsHeld = awakeSecondsHeld
        self.lastTool = lastTool
        self.lastOutcome = lastOutcome
        self.deniedCount = deniedCount
        self.rateLimitedCount = rateLimitedCount
        self.erroredCount = erroredCount
        self.holdsKeepAwakeNow = holdsKeepAwakeNow
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
    /// - Parameter keepAwakeOwners: the `AgentAwakeHold.owner` value(s) whose
    ///   held time should count toward `keepAwakeSecondsHeld` — additive
    ///   (CLI session-scoping pass). Defaults to `nil`, which keeps every
    ///   existing call site's exact behavior: sum over `[sessionID]` alone,
    ///   the single connection this attribution is for. `sentryctl
    ///   session-report --client=<name>` scopes by self-reported client name
    ///   rather than one connection, and a client name can span several
    ///   connections (several real `sessionID`s) within the same window —
    ///   see `MCPXPCService.getSessionResourceReport(targetClientName:)`,
    ///   which passes every distinct `sessionID` seen among `events` for
    ///   that name here instead of relying on the single-`sessionID` default.
    ///   Holds are summed, never double-counted: each `AgentAwakeHold` has
    ///   exactly one owner, so passing disjoint owners can only add
    ///   non-overlapping holds together.
    public static func attribution(
        sessionID: String,
        clientName: String,
        events: [AgentActivityEvent],
        awakeHolds: [AgentAwakeHold],
        batterySamples: [(timestamp: Date, value: Double)],
        thermalPressureSamples: [(timestamp: Date, value: Double)],
        window: ClosedRange<Date>,
        externalCaffeinateMatches: [CaffeinateArbitrator.ExternalCaffeinateMatch]? = nil,
        keepAwakeOwners: [String]? = nil
    ) -> AgentSessionAttribution {
        var toolCounts: [String: Int] = [:]
        for event in events {
            toolCounts[event.tool, default: 0] += 1
        }
        let thermal = thermalElevation(samples: thermalPressureSamples, windowStart: window.lowerBound)
        let matches = externalCaffeinateMatches ?? []
        let owners = keepAwakeOwners ?? [sessionID]
        let keepAwakeSeconds = owners.reduce(0.0) { total, owner in
            total + awakeSeconds(holds: awakeHolds, owner: owner, window: window)
        }
        return AgentSessionAttribution(
            sessionID: sessionID,
            clientName: clientName,
            sessionStart: events.map(\.timestamp).min(),
            sessionEnd: events.map(\.timestamp).max(),
            callCount: events.count,
            toolCallCounts: toolCounts,
            keepAwakeSecondsHeld: keepAwakeSeconds,
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

    /// How recently a session must have called for
    /// `AgentSessionSummary.isActive(asOf:)` to still call it connected.
    ///
    /// **Aliased to `AgentSessionRegistry.staleAfter`, not re-picked.** The
    /// registry already owns this app's one answer to "when does a session
    /// stop counting as present," with a documented rationale (XPC surfaces
    /// no per-MCP-session disconnect, so silence is the only signal, and the
    /// failure modes are asymmetric). A second threshold chosen here would
    /// mean the Dashboard could call a session ended while `preflight_check`
    /// still reports `another_agent_active` for it — two surfaces
    /// contradicting each other about the same session. Deriving the value
    /// makes that contradiction impossible by construction.
    ///
    /// The two are nonetheless answering the question from opposite sides:
    /// the registry prunes *live in-memory rows*, this classifies *rows read
    /// back out of SQLite* long after the fact. That's why the classification
    /// lives here (a pure function over persisted events) rather than
    /// becoming a method on the main-actor-isolated registry, which the
    /// Dashboard's report path has no reason to touch.
    public static let activeWithin: TimeInterval = AgentSessionRegistry.staleAfter

    /// Groups a window's events into per-session summaries, most recent
    /// last-activity first — the Dashboard `AgentActivityCard`'s data
    /// source. Awake time per session comes from the in-memory ledger, so
    /// it only covers holds from the current app run (see
    /// `AgentAwakeHold`'s doc comment); sessions older than the current run
    /// honestly show zero rather than a reconstructed guess.
    ///
    /// **Last-call fields are found by `max(by: timestamp)`, not by taking
    /// `events.last`.** `HistoryStore.agentActivityEvents` happens to return
    /// rows oldest-first today, but nothing in this function's signature
    /// says so, and a caller that filters or re-sorts before calling would
    /// otherwise silently make the card claim the wrong "last tool." Same
    /// reasoning the existing `start`/`end` lines already apply by using
    /// `min()`/`max()` instead of `first`/`last`.
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
                let end = sessionEvents.map(\.timestamp).max(),
                let lastEvent = sessionEvents.max(by: { $0.timestamp < $1.timestamp })
            else { return nil }
            var toolCounts: [String: Int] = [:]
            var denied = 0
            var rateLimited = 0
            var errored = 0
            for event in sessionEvents {
                toolCounts[event.tool, default: 0] += 1
                switch event.outcome {
                case .denied: denied += 1
                case .rateLimited: rateLimited += 1
                case .errored: errored += 1
                case .succeeded: break
                }
            }
            // Legacy groups are keyed by *client name*, not session ID, and
            // the ledger's owners are session IDs — so they can neither
            // claim held time nor claim to be holding one now. Both guards
            // are the same guard; keeping them adjacent is why.
            let isLegacy = key.hasPrefix(legacyGroupPrefix)
            let awake = isLegacy
                ? 0
                : awakeSeconds(holds: awakeHolds, owner: key, window: start...max(now, end))
            let holdingNow = !isLegacy && awakeHolds.contains { $0.owner == key && $0.end == nil }
            return AgentSessionSummary(
                id: key,
                clientName: sessionEvents.first?.clientName ?? "",
                start: start,
                end: end,
                callCount: sessionEvents.count,
                toolCallCounts: toolCounts,
                awakeSecondsHeld: awake,
                lastTool: lastEvent.tool,
                lastOutcome: lastEvent.outcome,
                deniedCount: denied,
                rateLimitedCount: rateLimited,
                erroredCount: errored,
                holdsKeepAwakeNow: holdingNow
            )
        }
        .sorted { $0.end > $1.end }
    }
}
