import Foundation

/// One row of the AI Access pane's live activity log (plan §13.4: "timestamp,
/// client identity, tool called, arguments, allow/deny"). Deliberately a
/// plain, small `Codable`-free value — this never leaves the process, so
/// there's no wire-format contract to keep stable, unlike `MCPToolID`'s raw
/// values.
public struct MCPActivityLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let clientName: String
    public let tool: MCPToolID
    /// A short, human-readable summary of the call's arguments — not the
    /// full JSON payload. This log is a user-facing audit trail, not a debug
    /// dump; keeping entries terse is what makes a long session's log
    /// actually scannable.
    public let argumentsSummary: String
    public let decision: MCPAccessController.Decision

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        clientName: String,
        tool: MCPToolID,
        argumentsSummary: String,
        decision: MCPAccessController.Decision
    ) {
        self.id = id
        self.timestamp = timestamp
        self.clientName = clientName
        self.tool = tool
        self.argumentsSummary = argumentsSummary
        self.decision = decision
    }
}

/// In-memory ring buffer backing the AI Access pane's live activity log
/// (plan §13.4). Deliberately not a new SQLite table: this is a live,
/// session-scoped audit view ("what has an agent asked for since I opened
/// this Mac"), not durable history a user needs to review after a restart —
/// `HistoryStore.alert_log` earns its persistence because alert firings are
/// rare and worth remembering across relaunches; MCP calls from a chatty
/// client could be dozens per minute, and persisting all of that forever
/// would be a second unbounded-growth table for a feature this pass has no
/// evidence anyone needs to review after the app quits.
///
/// `@MainActor`-isolated, same reasoning as `PowerControlService`/
/// `AlertEngine`: driven by infrequent XPC calls, not a hot polling loop, and
/// it's the direct data source for a SwiftUI list (`AIAccessPane`), so
/// isolating writes to the actor the UI already reads from avoids a
/// publish-from-background-thread bug class for free.
@MainActor
public final class MCPActivityLog: ObservableObject {

    /// Most recent first — what a live log view wants to render without
    /// reversing on every update.
    @Published public private(set) var entries: [MCPActivityLogEntry] = []

    private let capacity: Int

    /// How many of `capacity`'s slots entries for calls that did **not**
    /// execute (denied, or a confirmation the user declined) are allowed to
    /// occupy.
    ///
    /// **Why this partition exists — audit-trail integrity.** Denied calls
    /// deliberately cost an attacker nothing: `MCPAccessController.evaluate`
    /// rejects them without consuming rate-limit budget (see `recordCall`'s
    /// doc comment on why that's right for the *rate limit*), so any local
    /// process that can reach the Mach service can issue denied calls as
    /// fast as XPC will carry them. In a single undifferentiated ring buffer
    /// that means a few hundred junk calls silently evict every record of
    /// what actually ran — i.e. the cheapest possible way to erase the
    /// evidence of a `keep_awake`/`create_alert_rule` that *was* allowed a
    /// moment earlier. Capping the unexecuted share means a flood can
    /// destroy at most `deniedCapacity` slots and never touches the entries
    /// that describe real, executed side effects.
    private let deniedCapacity: Int

    /// Number of entries currently in `entries` whose decision is anything
    /// other than `.allow`. Maintained incrementally rather than recomputed,
    /// since `record` runs on the main actor on the XPC hot path.
    private var unexecutedCount = 0

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
        self.deniedCapacity = max(1, self.capacity / 2)
    }

    public func record(_ entry: MCPActivityLogEntry) {
        entries.insert(entry, at: 0)
        if entry.decision != .allow { unexecutedCount += 1 }

        // Over the unexecuted share: drop the *oldest* unexecuted entry
        // rather than the oldest entry overall, so a denial flood only ever
        // recycles its own slots.
        if unexecutedCount > deniedCapacity,
           let oldestUnexecuted = entries.lastIndex(where: { $0.decision != .allow }) {
            entries.remove(at: oldestUnexecuted)
            unexecutedCount -= 1
        }

        while entries.count > capacity {
            let removed = entries.removeLast()
            if removed.decision != .allow { unexecutedCount -= 1 }
        }
    }

    public func clear() {
        entries.removeAll()
        unexecutedCount = 0
    }
}

/// Pure authorization-decision + rate-limiting logic for the MCP permission
/// model (plan §13.4). This is the one piece of the whole MCP surface that
/// genuinely needs to be a security boundary, not just a thin adapter — see
/// the plan's own framing (§13.2, point 3): "the MCP server can't do
/// anything the user hasn't enabled in Settings," and that promise has to be
/// enforced *here*, on the app side of the XPC boundary, because the spawned
/// `SentryMCP` binary is an external, untrusted-by-default process. A write
/// tool that's "off by default" but executes anyway when called would be
/// exactly the kind of silent-overclaim bug this codebase's P5 house rule
/// exists to catch — so `evaluate(tool:settings:)` is deliberately pure and
/// side-effect-free (easy to unit test exhaustively) and callers
/// (`MCPXPCService`) are required to check it — and get `.allow` — before
/// touching `StatsCoordinator`/`PowerControlService`/`AlertEngine` at all.
///
/// **Rate limiting is stateful** (an actual call history, unlike the pure
/// enable/disable checks), so this type can't be a free function the way
/// `AlertEngine.defaultRules` is — it needs to remember recent call
/// timestamps across invocations, hence a class with an injectable clock
/// (same testability pattern as `AlertEngine`'s `clock` parameter).
///
/// **Confirmation is a decision, not an action.** `.requiresConfirmation`
/// tells the caller to show a native dialog and wait; it deliberately does
/// *not* consume a rate-limit slot by itself (see `recordCall`'s doc
/// comment) — a call a human declines shouldn't count against the budget
/// the same way an executed one does.
public final class MCPAccessController {

    public enum Decision: Equatable, Sendable {
        /// Every gate passed; the caller may execute the tool immediately.
        case allow
        /// Plan §13.4's master enable/disable switch is off. Takes priority
        /// over every other check — nothing about a per-tool toggle matters
        /// if MCP itself is off.
        case denyMasterDisabled
        /// The specific tool is disabled — either its own per-tool toggle,
        /// or (for a write tool) the coarser `mcpWriteToolsEnabled` switch
        /// that gates every write tool at once (plan §13.4: "read-only
        /// tooling is a much smaller trust decision").
        case denyToolDisabled
        /// Plan §13.4's "max N tool calls/minute" cap has been reached.
        case denyRateLimited
        /// The tool is enabled and within the rate limit, but its
        /// "require confirmation" checkbox is on — the caller must show a
        /// native confirmation dialog and call `evaluate` again (or act on
        /// the user's choice directly) rather than executing outright.
        case requiresConfirmation
        /// A conditional guardrail or termination control blocked the call —
        /// the kill switch, a per-client revocation, the battery floor, the
        /// on-battery restriction, quiet hours, or thermal pressure.
        /// `reason` carries the full, honest sentence the agent should see
        /// verbatim ("Sentry declined this: battery is at 14% and
        /// unplugged…"). Produced by `MCPXPCService.authorize` from
        /// `AgentGuardrails.evaluate`
        /// (`SentryKit/Services/AgentGuardrails.swift`), never by
        /// `evaluate(tool:settings:)` here — the static permission model and
        /// the conditional guardrails are separate engines on purpose, so
        /// each stays exhaustively unit-testable on its own inputs.
        case denyGuardrail(reason: String)

        /// Whether this decision represents a genuine denial — used by
        /// `MCPXPCService` to decide whether to log `"denied"` vs
        /// `"allowed"` in the activity log, and by tests that just want to
        /// assert "was this blocked" without matching every specific reason.
        public var isDenied: Bool {
            switch self {
            case .allow, .requiresConfirmation: return false
            case .denyMasterDisabled, .denyToolDisabled, .denyRateLimited, .denyGuardrail: return true
            }
        }
    }

    private let clock: () -> Date

    /// Timestamps of calls actually recorded (via `recordCall`), keyed by
    /// the caller's display `clientName`, each pruned to roughly the last 60
    /// seconds lazily on each check — same "no timer of its own" pattern
    /// `AlertEngine.pruneRateCapWindow` uses for its hourly rate cap, just
    /// windowed to a minute per plan §13.4's "calls/minute" wording.
    ///
    /// **Per-client, not one shared window.** Before this pass every caller
    /// drew from a single array, which meant `settings.mcpRateLimitPerMinute`
    /// was actually a *Mac-wide* budget: one chatty or hostile MCP client
    /// (or a bug that reconnects in a loop) could consume the whole thing
    /// and starve every other agent — directly undermining the multi-agent
    /// coordination the rest of this surface exists to support
    /// (`AgentSessionRegistry`, `get_agent_capacity`, `preflight_check`'s
    /// `another_agent_active` reason all assume several well-behaved agents
    /// can share this Mac). Keying by `clientName` gives each caller its own
    /// `settings.mcpRateLimitPerMinute`-sized budget, same as the plan
    /// always described it per-agent, not shared.
    ///
    /// **`clientName` here is the *parsed display name*, never the raw wire
    /// string.** `MCPXPCService.authorize(tool:clientName:argumentsSummary:)`
    /// is called only after `sessionIdentity(fromWire:)`
    /// (`Sentry/App/MCPXPCService.swift`) has stripped the per-connection
    /// `AgentSessionIdentity` UUID suffix — using the wire string instead
    /// would mean every single call from the same long-running agent looks
    /// like a brand-new "client" with a fresh, empty budget, and the limiter
    /// would never trigger no matter how fast that agent called. Like every
    /// other use of a client name on this boundary, it is still
    /// self-reported and unauthenticated (see
    /// `SentryXPCServiceProtocol`'s doc comment) — a hostile process can
    /// dodge its own per-client budget by rotating names, which is exactly
    /// what `globalCeilingMultiplier` below exists to bound.
    private var callHistoryByClient: [String: [Date]] = [:]

    /// How many times larger the Mac-wide ceiling is than any single
    /// client's configured `mcpRateLimitPerMinute` budget.
    ///
    /// **Why a global ceiling exists at all**, given the window above is now
    /// per-client: per-client budgets stop one client from starving
    /// *another specific* client, but they do nothing to stop a hostile
    /// process from defeating the whole cap by simply reconnecting under a
    /// new self-reported `clientName` on every burst (see the doc comment
    /// above — names are unauthenticated) or from many distinct well-behaved
    /// agents all legitimately running near their own limit at once and
    /// collectively hammering `StatsCoordinator`/`HistoryStore` harder than
    /// this Mac should take from an MCP surface. A second, Mac-wide cap
    /// closes that gap without reintroducing the single-shared-window bug
    /// this pass exists to fix.
    ///
    /// **Why 4x, not 1x or 20x.** It has to sit "well above any single
    /// client's budget" (this task's brief) so that hitting it is a genuine
    /// signal of either many simultaneous legitimate agents or one client
    /// spoofing several names — not something one busy-but-honest agent
    /// grazes on its own. At the same time it has to be a real ceiling, not
    /// a formality: at the default 20/min per client, 1x (20/min total)
    /// would defeat the entire point of a *per-client* budget by collapsing
    /// back into a single shared window the moment two clients are both
    /// active; 20x (400/min) is high enough that a rotating-name attacker
    /// would barely notice it. 4x lands at 80/min by default — comfortably
    /// enough for several agents each legitimately working near their own
    /// cap (this is the same "generous because the failure modes are
    /// asymmetric" reasoning `AgentSessionRegistry.staleAfter` documents for
    /// its own threshold), while still capping the Mac-wide MCP call volume
    /// at a small, bounded multiple of what one client is allowed — a name-
    /// rotating attacker still cannot exceed it just by relabeling itself.
    static let globalCeilingMultiplier = 4

    /// Serializes every read/write of `callHistoryByClient`.
    ///
    /// Today every caller happens to reach this type from `MCPXPCService`'s
    /// `@MainActor` hop, so the window is de facto serialized — but nothing
    /// in this type's signature *enforces* that, and it is now reachable
    /// from two transports (the stdio `SentryMCP` XPC connection and
    /// `MCPRemoteServer`'s NIO event loop, via `LocalXPCServiceCaller`) whose
    /// threading is owned by frameworks, not by this app. A rate limiter
    /// that can be raced is a rate limiter an attacker can overrun, and the
    /// lock costs nothing at this call volume (tens of calls a minute), so
    /// it does not rely on a convention a future refactor could quietly
    /// break.
    private let lock = NSLock()

    /// - Parameter clock: injectable so tests can drive rate-limit windows
    ///   deterministically without real `sleep()` calls — same convention as
    ///   `AlertEngine.clock`.
    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Pure decision given the current settings snapshot. Never mutates
    /// `callHistoryByClient` on its own — see `recordCall`'s doc comment
    /// for why recording is a separate, explicit step the caller performs
    /// only once a call is genuinely going to execute.
    ///
    /// - Parameter clientName: the caller's *parsed display name* — see
    ///   `callHistoryByClient`'s doc comment for why the raw wire string
    ///   must never be passed here.
    public func evaluate(tool: MCPToolID, clientName: String, settings: AppSettings) -> Decision {
        guard settings.mcpServerEnabled else { return .denyMasterDisabled }

        if tool.isWrite && !settings.mcpWriteToolsEnabled {
            return .denyToolDisabled
        }
        guard settings.mcpEnabledToolIDs.contains(tool.rawValue) else {
            return .denyToolDisabled
        }
        guard !isRateLimited(clientName: clientName, limitPerMinute: settings.mcpRateLimitPerMinute) else {
            return .denyRateLimited
        }
        if tool.isWrite && settings.mcpConfirmationRequiredToolIDs.contains(tool.rawValue) {
            return .requiresConfirmation
        }
        return .allow
    }

    /// Whether `clientName`'s own rate-limit window is already at (or over)
    /// capacity, **or** the Mac-wide `globalCeilingMultiplier` ceiling
    /// across every client is — without recording anything. `evaluate` uses
    /// this to decide `.denyRateLimited` before any confirmation dialog is
    /// even shown, so a client hammering a rate-limited tool can't queue up
    /// a pile of pending confirmation prompts.
    public func isRateLimited(clientName: String, limitPerMinute: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneAllLocked()
        let clampedLimit = max(0, limitPerMinute)
        let globalCeiling = clampedLimit * Self.globalCeilingMultiplier
        let totalCallsAcrossAllClients = callHistoryByClient.values.reduce(0) { $0 + $1.count }
        if totalCallsAcrossAllClients >= globalCeiling {
            return true
        }
        let clientCalls = callHistoryByClient[clientName]?.count ?? 0
        return clientCalls >= clampedLimit
    }

    /// Records a call that is genuinely about to execute (post-confirmation,
    /// if any was required) against `clientName`'s rate-limit window.
    /// Deliberately not folded into `evaluate` itself: `evaluate` is called
    /// once to decide whether to show a confirmation dialog, and — if the
    /// user approves — the caller checks the *decision* again isn't needed,
    /// but it must still call `recordCall` exactly once per call that
    /// actually reaches `StatsCoordinator`/`PowerControlService`/
    /// `AlertEngine`. Two calls that both got `.allow` but where the second
    /// was for a tool the user then declined via confirmation must not both
    /// consume rate-limit budget — only the one that truly ran should.
    ///
    /// - Parameter clientName: same "parsed display name, not the wire
    ///   string" contract as `evaluate` — recording against the wrong key
    ///   would silently reopen the shared-budget bug this per-client window
    ///   exists to close.
    public func recordCall(clientName: String) {
        lock.lock()
        defer { lock.unlock() }
        pruneAllLocked()
        callHistoryByClient[clientName, default: []].append(clock())
    }

    /// Must be called with `lock` already held. Prunes every client's
    /// window, not just the one about to be read/written — the global
    /// ceiling in `isRateLimited` sums across all clients, so a stale
    /// timestamp sitting in some *other* client's history would otherwise
    /// silently inflate that total forever. Also drops any client whose
    /// window has emptied out entirely, so a Mac that saw thousands of
    /// distinct (or spoofed) client names over its uptime doesn't keep an
    /// ever-growing dictionary of empty arrays.
    private func pruneAllLocked() {
        let cutoff = clock().addingTimeInterval(-60)
        for key in callHistoryByClient.keys {
            callHistoryByClient[key]?.removeAll { $0 < cutoff }
        }
        callHistoryByClient = callHistoryByClient.filter { !$0.value.isEmpty }
    }
}
