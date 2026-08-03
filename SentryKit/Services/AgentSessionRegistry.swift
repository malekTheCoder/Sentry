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
            sessions[clientName] = session
        } else {
            // New name, or a stale row this same name left behind — either
            // way this is a fresh session, so `connectedAt` restarts rather
            // than claiming continuity across the idle gap.
            sessions[clientName] = Session(
                clientName: clientName,
                connectedAt: now,
                lastCallAt: now,
                recentTools: [tool],
                holdsKeepAwake: false
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
}
