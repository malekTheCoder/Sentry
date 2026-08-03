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

        /// Whether this decision represents a genuine denial — used by
        /// `MCPXPCService` to decide whether to log `"denied"` vs
        /// `"allowed"` in the activity log, and by tests that just want to
        /// assert "was this blocked" without matching every specific reason.
        public var isDenied: Bool {
            switch self {
            case .allow, .requiresConfirmation: return false
            case .denyMasterDisabled, .denyToolDisabled, .denyRateLimited: return true
            }
        }
    }

    private let clock: () -> Date

    /// Timestamps of calls actually recorded (via `recordCall`) in roughly
    /// the last 60 seconds, pruned lazily on each check — same "no timer of
    /// its own" pattern `AlertEngine.pruneRateCapWindow` uses for its hourly
    /// rate cap, just windowed to a minute per plan §13.4's "calls/minute"
    /// wording.
    private var recentCallTimestamps: [Date] = []

    /// Serializes every read/write of `recentCallTimestamps`.
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
    /// `recentCallTimestamps` on its own — see `recordCall`'s doc comment
    /// for why recording is a separate, explicit step the caller performs
    /// only once a call is genuinely going to execute.
    public func evaluate(tool: MCPToolID, settings: AppSettings) -> Decision {
        guard settings.mcpServerEnabled else { return .denyMasterDisabled }

        if tool.isWrite && !settings.mcpWriteToolsEnabled {
            return .denyToolDisabled
        }
        guard settings.mcpEnabledToolIDs.contains(tool.rawValue) else {
            return .denyToolDisabled
        }
        guard !isRateLimited(limitPerMinute: settings.mcpRateLimitPerMinute) else {
            return .denyRateLimited
        }
        if tool.isWrite && settings.mcpConfirmationRequiredToolIDs.contains(tool.rawValue) {
            return .requiresConfirmation
        }
        return .allow
    }

    /// Whether the rate-limit window is already at (or over) capacity,
    /// without recording anything — `evaluate` uses this to decide
    /// `.denyRateLimited` before any confirmation dialog is even shown, so a
    /// client hammering a rate-limited tool can't queue up a pile of pending
    /// confirmation prompts.
    public func isRateLimited(limitPerMinute: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneWindowLocked()
        return recentCallTimestamps.count >= max(0, limitPerMinute)
    }

    /// Records a call that is genuinely about to execute (post-confirmation,
    /// if any was required) against the rate-limit window. Deliberately not
    /// folded into `evaluate` itself: `evaluate` is called once to decide
    /// whether to show a confirmation dialog, and — if the user approves —
    /// the caller checks the *decision* again isn't needed, but it must
    /// still call `recordCall` exactly once per call that actually reaches
    /// `StatsCoordinator`/`PowerControlService`/`AlertEngine`. Two calls
    /// that both got `.allow` but where the second was for a tool the user
    /// then declined via confirmation must not both consume rate-limit
    /// budget — only the one that truly ran should.
    public func recordCall() {
        lock.lock()
        defer { lock.unlock() }
        pruneWindowLocked()
        recentCallTimestamps.append(clock())
    }

    /// Must be called with `lock` already held.
    private func pruneWindowLocked() {
        let cutoff = clock().addingTimeInterval(-60)
        recentCallTimestamps.removeAll { $0 < cutoff }
    }
}
