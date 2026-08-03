import Foundation

#if os(macOS)

/// The client half of command-line access: how `macstat` and `MacStatMCP`
/// reach a running Sentry.
///
/// **Read `MacStatKit/MCPBridge/MCPBridgeContract.swift` first.** This type
/// used to be four lines of `NSXPCConnection(machServiceName:)` pointed at a
/// name that nothing had ever registered with launchd, which is why every
/// invocation of both binaries failed — with a message blaming the app for not
/// running, while the app was running. It now performs a two-step rendezvous:
///
///   1. Connect to `MCPBridgeNaming.machService`, owned by the on-demand
///      LaunchAgent, and ask it where Sentry is.
///   2. Connect **directly** to the anonymous endpoint it hands back.
///
/// Step 2 is a direct app↔tool connection; the bridge is not on the data path
/// and never sees a tool call.
///
/// **Every failure of the rendezvous names its own cause, and that is the
/// point of the exercise.** The three ways this can fail are three different
/// problems with three different fixes:
///
///   * the bridge isn't registered (or is registered and not yet approved) —
///     nothing to do with whether Sentry is running, and the state the old
///     code mislabelled;
///   * the bridge is running and Sentry has not published to it — Sentry
///     genuinely is not running, and now we can say so *because* we got an
///     answer from something;
///   * the endpoint resolved and connecting to it failed — Sentry quit between
///     the two steps, or the signatures don't match.
///
/// Every one of those messages begins with `unreachablePrefix`, which is how
/// callers (`macstat statusline`, notably) distinguish a connection-level
/// failure — eligible for the stale-reading fallback — from a permission
/// denial coming back from `MCPXPCService`, which is not.
///
/// **A fresh proxy per call, still.** Each call gets its own
/// `remoteObjectProxyWithErrorHandler` rather than one cached proxy, so a
/// connection interruption between calls surfaces as a clear per-call error
/// instead of every subsequent call silently hanging. The *connection* is
/// cached (resolving it costs a round trip and possibly a launchd cold start);
/// the proxy is not.
public final class MacStatXPCClient: MCPServiceCalling, @unchecked Sendable {

    /// Every connection-level failure message starts with this.
    ///
    /// Exported rather than left as a string literal because `MacStatCLI`
    /// branches on it — `statusline` may fall back to its cached reading when
    /// Sentry is unreachable, but must never do so when the real answer was
    /// "the user turned this tool off in Settings". That was a magic substring
    /// matched in two files; it is now one constant, and the wording can
    /// change without silently breaking the branch.
    public static let unreachablePrefix = "Couldn't reach Sentry"

    private let broker: ConnectionBroker

    public init() {
        broker = ConnectionBroker()
    }

    public func readCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Data?, String?) -> Void) -> Void) async -> (Data?, String?) {
        switch await broker.connection() {
        case .unreachable(let reason):
            return (nil, reason)
        case .connected(let connection):
            return await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, String?), Never>) in
                let box = ResumeOnce(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [broker] (error: Error) in
                    Task { await broker.dropConnection() }
                    box.resume((nil, Self.callFailure(error)))
                }) as? MacStatXPCServiceProtocol else {
                    box.resume((nil, Self.mismatchedInterface))
                    return
                }
                body(proxy) { data, message in box.resume((data, message)) }
            }
        }
    }

    public func writeCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Bool, String?) -> Void) -> Void) async -> (Bool, String?) {
        switch await broker.connection() {
        case .unreachable(let reason):
            return (false, reason)
        case .connected(let connection):
            return await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
                let box = ResumeOnce(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [broker] (error: Error) in
                    Task { await broker.dropConnection() }
                    box.resume((false, Self.callFailure(error)))
                }) as? MacStatXPCServiceProtocol else {
                    box.resume((false, Self.mismatchedInterface))
                    return
                }
                body(proxy) { ok, message in box.resume((ok, message)) }
            }
        }
    }

    /// A call failed on an already-resolved connection. Distinct from every
    /// rendezvous failure: we *did* find Sentry, and it stopped answering.
    static func callFailure(_ error: Error) -> String {
        "\(unreachablePrefix): the connection to it failed mid-call (\(error.localizedDescription)). Sentry may have just quit."
    }

    static let mismatchedInterface =
        "\(unreachablePrefix): it answered with something this tool doesn't recognise as Sentry's interface. This `macstat` and Sentry.app are probably different versions."
}

/// The outcome of a rendezvous.
///
/// A plain enum rather than `Result`, because the failure side is a
/// *user-facing sentence*, not an `Error`. Wrapping these strings in an error
/// type would add a layer whose only job is to be unwrapped again two lines
/// later — `MCPServiceCalling`'s whole contract is `(value?, message?)`, for
/// the reason `MacStatXPCServiceProtocol` documents at length (an `@objc` XPC
/// protocol cannot carry Swift errors, so the message *is* the currency here).
enum MCPRendezvous {
    case connected(NSXPCConnection)
    case unreachable(String)
}

/// Same shape for the intermediate step. Kept separate from `MCPRendezvous`
/// so a `case .connected` cannot silently compile against the wrong stage.
enum MCPEndpointLookup {
    case resolved(NSXPCListenerEndpoint)
    case unreachable(String)
}

/// Resolves and caches the direct connection to Sentry.
///
/// An `actor` rather than a lock because resolution is genuinely asynchronous
/// (a round trip to the bridge, possibly behind a launchd cold start) and two
/// concurrent tool calls on a fresh process would otherwise each start their
/// own rendezvous. Actor re-entrancy means they can still both *enter*
/// `connection()`; the cheap `if let` at the top means the second one takes the
/// first one's result the moment it lands, and the worst case is one redundant
/// resolve, never a redundant connection handed to a caller.
private actor ConnectionBroker {

    private var appConnection: NSXPCConnection?

    func dropConnection() {
        appConnection?.invalidate()
        appConnection = nil
    }

    func connection() async -> MCPRendezvous {
        if let appConnection { return .connected(appConnection) }

        switch await resolveEndpoint() {
        case .unreachable(let reason):
            return .unreachable(reason)
        case .resolved(let endpoint):
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: MacStatXPCServiceProtocol.self)
            connection.resume()
            appConnection = connection
            return .connected(connection)
        }
    }

    /// One round trip to the bridge.
    ///
    /// The bridge connection is deliberately **not** cached: it is used once
    /// per process to fetch an endpoint, and holding it open would keep an
    /// otherwise-idle agent from reaching its idle-exit timer for as long as a
    /// long-lived `MacStatMCP` session lasts. Sentry holds the connection that
    /// matters; a consumer does not need to.
    private func resolveEndpoint() async -> MCPEndpointLookup {
        let bridge = NSXPCConnection(machServiceName: MCPBridgeNaming.machService)
        bridge.remoteObjectInterface = NSXPCInterface(with: MCPBridgeProtocol.self)
        bridge.resume()
        defer { bridge.invalidate() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<MCPEndpointLookup, Never>) in
            let box = ResumeOnce(continuation)

            // Bounded. Without this a wedged agent hangs the caller forever;
            // `macstat` is run from shell prompts and `PreToolUse` hooks, where
            // "hangs forever" is the worst available failure mode.
            DispatchQueue.global().asyncAfter(deadline: .now() + MCPBridgeTiming.resolveTimeout) {
                box.resume(.unreachable(Self.bridgeTimedOut))
            }

            guard let proxy = bridge.remoteObjectProxyWithErrorHandler({ (error: Error) in
                box.resume(.unreachable(Self.bridgeUnreachable(error)))
            }) as? MCPBridgeProtocol else {
                box.resume(.unreachable(Self.bridgeUnreachable(
                    NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "the bridge interface couldn't be created"
                    ])
                )))
                return
            }

            proxy.resolveAppEndpoint { endpoint, message in
                guard let endpoint else {
                    // Getting *any* answer here proves the bridge is
                    // registered, approved, and running — so this branch can
                    // only mean Sentry itself isn't there, and the bridge's own
                    // wording says exactly that. Passed through rather than
                    // re-improvised, so there is one place that sentence lives.
                    box.resume(.unreachable(
                        "\(MacStatXPCClient.unreachablePrefix): \(message ?? "its command-line bridge is running but had no connection point for Sentry.")"
                    ))
                    return
                }
                box.resume(.resolved(endpoint))
            }
        }
    }

    /// The message that replaces "Is MacStat running?" — the wrong question,
    /// asked for the entire life of this feature.
    ///
    /// It is long, and that is a considered choice. A user hitting this is
    /// looking at a tool that fails while the app it names is visibly running
    /// in their menu bar; the shortest honest message that actually resolves
    /// that has to name the background item, say where to set it up, and say
    /// where macOS might be holding it. The alternative — a terse line plus a
    /// documentation link — was what the previous version effectively was.
    static func bridgeUnreachable(_ error: Error) -> String {
        """
        \(MacStatXPCClient.unreachablePrefix): its command-line bridge isn't available (\(error.localizedDescription)).

        `macstat` and the stdio MCP server don't talk to Sentry directly — they go through a small background item that macOS starts on demand, and it has to be set up once. Sentry running is not enough on its own.

          1. In Sentry, open Settings ▸ AI Access and choose "Set Up Command-Line Access".
          2. If you've already done that, open System Settings ▸ General ▸ Login Items & Extensions and make sure Sentry's background item is switched on.

        If setup there reports that macOS refused, this copy of Sentry probably wasn't signed with a Developer ID certificate, and command-line access can't work for it. Sentry's other features, including MCP over HTTP, are unaffected.
        """
    }

    static let bridgeTimedOut =
        "\(MacStatXPCClient.unreachablePrefix): its command-line bridge didn't answer within \(Int(MCPBridgeTiming.resolveTimeout)) seconds. It may be wedged; quitting and reopening Sentry, or logging out and back in, will restart it."
}

/// Resumes a `CheckedContinuation` at most once, guarded by a lock. Needed
/// because `remoteObjectProxyWithErrorHandler`'s error handler and the XPC
/// reply block are two independent completion paths that a real connection
/// failure mid-call can race between — `NSXPCConnection`'s own contract only
/// promises *one* of them fires per call, not which, and calling
/// `continuation.resume` twice is a Swift Concurrency crash, not a warning.
///
/// Now also guards the rendezvous, where there are *three* racing paths
/// rather than two (reply, connection error, and the resolve timeout). That
/// third one makes this type load-bearing rather than merely defensive: a
/// bridge that answers at the 5.001-second mark is not an exotic scenario, it
/// is a cold start under load.
final class ResumeOnce<T>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var didResume = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let alreadyResumed = didResume
        didResume = true
        lock.unlock()
        guard !alreadyResumed else { return }
        continuation.resume(returning: value)
    }
}

#endif
