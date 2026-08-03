import Foundation

#if os(macOS)

/// The bridge's **entire** API surface. Three methods, none of which carries
/// telemetry, a client name, or anything a permission decision could be made
/// from.
///
/// **Why this is a rendezvous protocol and not a proxy of
/// `MacStatXPCServiceProtocol`.** See `MCPBridgeContract`'s header for the
/// full argument; the short version is that a bridge which forwarded tool
/// calls would need a method per tool, would need editing every time a tool
/// is added, and would become a second place where "is this client allowed to
/// do this?" could plausibly be answered. It cannot answer that question
/// because it is never asked it. `MCPAccessController`, inside Sentry,
/// remains the only authorization boundary for tool use — unchanged by this
/// change, and unchanged in where it lives.
///
/// **What the bridge knows about a caller.** Only what the peer gate
/// establishes: that the connecting process's code signature satisfies a
/// requirement (`MCPBridgePeerGate`). It does not know, log, or forward the
/// caller's MCP client name — `clientName` still travels on
/// `MacStatXPCServiceProtocol`'s own methods, directly from the tool to
/// Sentry over the connection this protocol hands out, never through here.
///
/// **`@objc` and the reply-block shape**, same constraint
/// `MacStatXPCServiceProtocol` documents at length: `NSXPCConnection`
/// requires an `@objc` protocol, so there is no `throws` and no Swift enum
/// crossing this boundary. Failures come back as an optional message string
/// beside the result. `NSXPCListenerEndpoint` is `NSSecureCoding` and is one
/// of the types XPC transports natively — passing one is the documented way
/// to introduce two processes that have no Mach service in common, which is
/// precisely the situation this protocol exists to resolve.
@objc public protocol MCPBridgeProtocol {

    /// Sentry hands the bridge the endpoint of its anonymous listener.
    ///
    /// Called by the app, and only by the app — the peer gate requires the
    /// caller to satisfy `MCPBridgePeerGate.publisherRequirement`, which pins
    /// Sentry's bundle identifier as well as the Team ID. Called again after
    /// any connection interruption, because a bridge that was restarted by
    /// launchd comes back with an empty table and there is nobody else who
    /// can refill it.
    ///
    /// - Parameter reply: `(true, nil)` on success, `(false, reason)` when
    ///   the bridge refused. The reason is displayed verbatim in Settings, so
    ///   it is written for a person rather than a log scraper.
    func publish(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool, String?) -> Void)

    /// Sentry withdraws its endpoint on orderly termination.
    ///
    /// Best-effort and deliberately unauthoritative: the bridge also drops
    /// the endpoint when the publishing connection invalidates, which is the
    /// path that actually covers a crash, a `SIGKILL`, or a force-quit. This
    /// method exists so the common case (the user quits Sentry) retires the
    /// entry immediately rather than leaving a stale endpoint for however
    /// long the kernel takes to tear the connection down — during which a
    /// `macstat` call would fail with a *less* accurate message than the one
    /// it deserves.
    func withdraw(reply: @escaping (Bool) -> Void)

    /// `macstat` / `MacStatMCP` ask where Sentry is.
    ///
    /// - Parameter reply: the endpoint, or `nil` plus a human-readable reason.
    ///   `nil` here means something specific and useful — *the bridge is alive
    ///   and reachable, and Sentry has not published to it* — which is how the
    ///   client can tell "the app isn't running" apart from "the bridge was
    ///   never registered." Those two produced an identical, and wrong, error
    ///   message before this change.
    func resolveAppEndpoint(reply: @escaping (NSXPCListenerEndpoint?, String?) -> Void)
}

#endif
