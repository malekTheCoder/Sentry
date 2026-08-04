import Foundation

/// In-memory record of which MCP clients have called this Mac recently —
/// the data behind `get_agent_capacity`'s session list and
/// `preflight_check`'s `another_agent_active` reason.
///
/// **Advisory, not a lock.** Sentry has no way to *prevent* two agents from
/// building at once (and shouldn't — see the tool descriptions in
/// `MCPToolCatalog`), so this registry exists purely to *inform*: "someone
/// else is mid-workload" is exactly the fact a well-behaved agent needs to
/// decide to wait, and exactly the fact it cannot observe on its own.
///
/// **Sessions are keyed by self-reported `clientName`.** There is no
/// authenticated identity on this boundary (see
/// `SentryXPCServiceProtocol`'s doc comment) — `clientName` is whatever the
/// client's `initialize` handshake claimed. Two clients announcing the same
/// name therefore collapse into one row, and a client can trivially
/// masquerade as another; every consumer of this registry says so rather
/// than presenting the labels as fact.
///
/// **"Connected" means "called recently."** XPC gives the app no per-MCP-
/// session connect/disconnect events (every tool call arrives over the same
/// brokered connection), so a session is *active* while its last call is
/// within `staleAfter` and silently expires afterwards — pruned lazily on
/// read rather than by a timer, because a registry nobody is querying
/// doesn't need to be tidy.
///
/// `@MainActor`-isolated like `MCPActivityLog` and every other piece of
/// state `MCPXPCService` touches — calls arrive via that service's
/// `Task { @MainActor in ... }` hops, so no further synchronization is
/// needed. Purely in-memory: session presence is a claim about *right now*,
/// so persisting it would only mint stale claims after relaunch.
@MainActor
public final class AgentSessionRegistry {

    /// Idle time after which a session stops counting as active. Generous
    /// on purpose: an agent mid-build may not call another tool for many
    /// minutes, and the failure modes are asymmetric — expiring a live
    /// session hides real contention from `preflight_check`, while keeping
    /// a dead one merely adds an advisory caution the caller can override.
    public static let staleAfter: TimeInterval = 15 * 60

    /// Cap on `Session.recentTools` — enough to characterize what a session
    /// is doing ("polling metrics" vs. "holding keep-awake and waiting")
    /// without becoming a second activity log; `MCPActivityLog` already
    /// keeps the full call history.
    public static let recentToolsLimit = 8

    public struct Session: Sendable, Equatable {
        /// Self-reported — see the type doc comment.
        public var clientName: String
        /// First call observed from this name (since app launch or since
        /// the name last expired) — not a transport-level connect time,
        /// which XPC doesn't surface per MCP session.
        public var connectedAt: Date
        public var lastCallAt: Date
        /// Most recent first, deduplicated, capped at `recentToolsLimit`.
        public var recentTools: [MCPToolID]
        /// Whether this session's last keep-awake action was a successful
        /// `keep_awake` (cleared on `release_awake` from anyone —
        /// `PowerControlService` holds at most one assertion, so a release
        /// releases *the* assertion regardless of who started it). Cross-
        /// check against the live assertion state before presenting this as
        /// "holds keep-awake now": the assertion may have expired on its
        /// own timer without another MCP call to tell the registry.
        public var holdsKeepAwake: Bool
        /// Total calls observed from this name since it last started a fresh
        /// session (see `recordCall`'s "new name, or a stale row" branch) —
        /// every call, allowed or denied, same "presence, not permission"
        /// scope `recordCall`'s doc comment gives `recentTools`. Unlike
        /// `recentTools`, never deduplicated or capped: this is a count, not
        /// a display list, and exists so `activitySummary(asOf:)` can report
        /// a real total instead of `recentTools.count`, which is a
        /// dedup-and-cap-8 window, not a total.
        public var callCount: Int
    }

    private var sessions: [String: Session] = [:]

    public init() {}

    /// Registers/refreshes the session for `clientName` — called for every
    /// tool call flowing through `MCPXPCService.authorize`, including denied
    /// ones (a denied client is still *present*, which is what this
    /// registry measures; what it was allowed to do is the activity log's
    /// story).
    public func recordCall(clientName: String, tool: MCPToolID, at now: Date = Date()) {
        if var session = sessions[clientName], now.timeIntervalSince(session.lastCallAt) <= Self.staleAfter {
            session.lastCallAt = now
            session.recentTools.removeAll { $0 == tool }
            session.recentTools.insert(tool, at: 0)
            if session.recentTools.count > Self.recentToolsLimit {
                session.recentTools.removeLast(session.recentTools.count - Self.recentToolsLimit)
            }
            session.callCount += 1
            sessions[clientName] = session
        } else {
            // New name, or a stale row this same name left behind — either
            // way this is a fresh session, so `connectedAt` restarts rather
            // than claiming continuity across the idle gap (and `callCount`
            // restarts at 1 rather than continuing a prior session's tally,
            // for the same reason).
            sessions[clientName] = Session(
                clientName: clientName,
                connectedAt: now,
                lastCallAt: now,
                recentTools: [tool],
                holdsKeepAwake: false,
                callCount: 1
            )
        }
    }

    /// Marks `clientName` as the keep-awake holder. Only ever one holder:
    /// `PowerControlService` owns at most one assertion, and a new
    /// `keep_awake` replaces the old assertion, so the flag moves rather
    /// than accumulates.
    public func recordKeepAwake(clientName: String, at now: Date = Date()) {
        for name in sessions.keys {
            sessions[name]?.holdsKeepAwake = false
        }
        // `keep_awake` flows through `recordCall` first, so the session
        // exists — but don't rely on call order for correctness.
        if sessions[clientName] == nil {
            recordCall(clientName: clientName, tool: .keepAwake, at: now)
        }
        sessions[clientName]?.holdsKeepAwake = true
    }

    /// Clears every keep-awake flag — on `release_awake` (whoever called
    /// it: one assertion, one release, see `Session.holdsKeepAwake`).
    public func clearKeepAwake() {
        for name in sessions.keys {
            sessions[name]?.holdsKeepAwake = false
        }
    }

    /// Sessions whose last call is within `staleAfter`, most recently
    /// active first. Prunes expired rows as a side effect (see the type doc
    /// comment for why pruning is lazy).
    public func activeSessions(asOf now: Date = Date()) -> [Session] {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastCallAt) <= Self.staleAfter }
        return sessions.values.sorted { $0.lastCallAt > $1.lastCallAt }
    }

    /// Active sessions other than the caller's own — what
    /// `preflight_check`'s `another_agent_active` reason counts. Excluding
    /// by name inherits the label caveat: two distinct clients announcing
    /// the caller's name are invisible here.
    public func otherActiveSessions(excluding clientName: String, asOf now: Date = Date()) -> [Session] {
        activeSessions(asOf: now).filter { $0.clientName != clientName }
    }

    /// Rolls every active session up into one Mac-wide `AgentActivitySummary`
    /// (`SentryKit/Models/SystemSnapshot.swift`) — the shape
    /// `SystemSnapshot.agentActivitySummary` carries and, from there,
    /// `WatchRelaySnapshot.agentToolCallCount`/`.agentLastActivityAt`/
    /// `.agentRecentToolNames` relay to the Watch. Deliberately Mac-wide
    /// rather than one session's view — see `AgentActivitySummary`'s own doc
    /// comment for why a single-session summary would misrepresent exactly
    /// the two-agents-at-once case this registry exists to surface.
    ///
    /// - `toolCallCount` is the sum of every active session's `callCount` —
    ///   a real total, not `recentTools.count` (which is a dedup-and-cap-8
    ///   display window, not a count).
    /// - `lastActivityAt` is the latest `lastCallAt` across active sessions,
    ///   `nil` only when there are none — the healthy common case.
    /// - `recentToolNames` merges each session's own most-recent-first
    ///   `recentTools`, walking sessions in `activeSessions`' most-recently-
    ///   active-first order and deduplicating by name as it goes, capped at
    ///   `recentToolsLimit`. **This is a session-recency merge, not a true
    ///   cross-session call-time merge** — `Session.recentTools` carries no
    ///   per-tool timestamp (see that property's doc comment), so a tool
    ///   called a minute ago by a currently-idle-but-still-active session can
    ///   list ahead of one called seconds ago by a different session, if the
    ///   first session's *other*, more recent call put it earlier in
    ///   `activeSessions`. Good enough for a glanceable "what's been
    ///   happening" list; not an audit trail (the Mac's AI Access pane, which
    ///   reads `MCPActivityLog` directly, is that).
    public func activitySummary(asOf now: Date = Date()) -> AgentActivitySummary {
        let sessions = activeSessions(asOf: now)
        let totalCalls = sessions.reduce(0) { $0 + $1.callCount }
        let lastActivity = sessions.map(\.lastCallAt).max()

        var seen = Set<MCPToolID>()
        var mergedNames: [String] = []
        for session in sessions {
            for tool in session.recentTools where !seen.contains(tool) {
                seen.insert(tool)
                mergedNames.append(tool.rawValue)
                if mergedNames.count >= Self.recentToolsLimit { break }
            }
            if mergedNames.count >= Self.recentToolsLimit { break }
        }

        return AgentActivitySummary(
            toolCallCount: totalCalls,
            lastActivityAt: lastActivity,
            recentToolNames: mergedNames
        )
    }
}
