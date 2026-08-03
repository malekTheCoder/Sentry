import Foundation

#if os(macOS)
import MCP

/// MCP Resource support (AI-agent-integration pass — see
/// Sentry-AI-Features-Research.md item #9). Before this, `SentryMCP` only
/// advertised `tools` (`capabilities: .init(tools: .init(listChanged: false))`
/// in `main.swift`); every "live" read was the client re-polling
/// `get_system_snapshot` itself. This adds one Resource,
/// `sentry://system-snapshot`, with subscribe support: a long-lived client
/// (a Claude Code session, a Cursor background agent) calls
/// `resources/subscribe` once and then gets a `notifications/resources/updated`
/// push instead of having to poll a tool call repeatedly — cheaper in both
/// latency and token cost for the exact "watch the machine" pattern
/// `wait_until_ready`/`preflight_check` exist to replace with a single
/// blocking call, and a complement to them for clients that want a live feed
/// instead.
///
/// **Why polling under the hood, not a true push, is still honest here:**
/// `SentryMCP` only talks to `Sentry.app` over synchronous XPC
/// request/reply calls (`SentryXPCServiceProtocol`) — there's no
/// server-initiated push channel from the app to this process. So
/// `ResourceSubscriptionPump` polls `get_system_snapshot` on a short
/// interval while at least one MCP client is subscribed, and only emits a
/// `notifications/resources/updated` when the snapshot's timestamp actually
/// advances. The client-facing contract (subscribe once, get pushed
/// updates, no repeated `tools/call`) is real; what's saved is the client's
/// token cost, not Sentry's own poll loop, which already runs regardless
/// (`StatsCoordinator`'s tiered `AsyncStream`).
///
/// **Why this lives in `SentryKit`, not the `SentryMCP` executable
/// target.** Originally this was `SentryMCP`-only (the stdio subprocess was
/// the only MCP transport). Once an in-app remote HTTP transport
/// (`Sentry/App/MCPRemoteServer.swift`) needed the identical tool/resource
/// dispatch logic, this became shared code — moved here so both transports
/// call one implementation rather than maintaining two copies. Gated behind
/// `#if os(macOS)` (matching `SentryXPCClient`/`SentryXPCProtocol`'s own
/// guard) since `SentryKit_iOS` compiles this same source directory but has
/// no XPC connection, no `MCP` package dependency, and no reason to carry
/// this code at all.
public enum ResourceCatalog {
    public static let systemSnapshotURI = "sentry://system-snapshot"

    public static let resources: [Resource] = [
        Resource(
            name: "system-snapshot",
            uri: systemSnapshotURI,
            description: "Live current values for all enabled metrics — the same payload as the get_system_snapshot tool, but subscribable via resources/subscribe.",
            mimeType: "application/json"
        )
    ]

    public static func read(uri: String, clientName: String, xpcClient: any MCPServiceCalling) async throws -> ReadResource.Result {
        guard uri == systemSnapshotURI else {
            throw MCPError.invalidParams("Unknown resource URI '\(uri)'.")
        }
        let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
        guard let data, let text = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError(message ?? "Sentry denied this request.")
        }
        return ReadResource.Result(contents: [.text(text, uri: uri, mimeType: "application/json")])
    }
}

/// Polls `get_system_snapshot` on a fixed interval while `subscriberCount`
/// is above zero, and calls `onUpdate` whenever the snapshot's `timestamp`
/// field advances — see `ResourceCatalog`'s doc comment for why polling
/// happens here rather than this being a true push from `Sentry.app`.
public actor ResourceSubscriptionPump {
    private let xpcClient: any MCPServiceCalling
    private let clientName: String
    private let pollInterval: Duration
    private var subscriberCount = 0
    private var pumpTask: Task<Void, Never>?
    private var lastTimestamp: Date?

    /// Consecutive polls that came back with no data — which, on this
    /// surface, overwhelmingly means *denied*, not "transient glitch":
    /// `resources/subscribe` is not itself gated by any `MCPToolID`, but the
    /// poll underneath it is a full `get_system_snapshot` call through
    /// `MCPAccessController`. So a client that subscribes while MCP access
    /// is off (or while `get_system_snapshot` is disabled, or after the user
    /// turns remote access off with a subscription still open) otherwise
    /// leaves this loop hammering the gate every `pollInterval` forever:
    /// 20 denied calls a minute, which is the *entire* default rate-limit
    /// budget (`AppSettings.mcpRateLimitPerMinute` = 20) plus 20 entries a
    /// minute of activity-log noise, for a subscription that will never
    /// deliver anything. Backing off exponentially to `maxPollInterval`
    /// keeps a legitimate subscription self-healing (it recovers the moment
    /// the user re-enables the tool) while making the denied case cheap.
    private var consecutiveFailures = 0

    /// Ceiling on the backoff above — long enough to be negligible, short
    /// enough that re-enabling the tool in Settings visibly recovers.
    private static let maxPollInterval: Duration = .seconds(60)

    public init(xpcClient: any MCPServiceCalling, clientName: String, pollInterval: Duration = .seconds(3)) {
        self.xpcClient = xpcClient
        self.clientName = clientName
        self.pollInterval = pollInterval
    }

    public func subscribe(onUpdate: @escaping @Sendable () async -> Void) {
        subscriberCount += 1
        // A newly-arrived subscriber deserves a prompt first poll even if a
        // previous one left the loop backed off.
        consecutiveFailures = 0
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while await self.isActive() {
                try? await Task.sleep(for: await self.nextPollDelay())
                await self.pollOnce(onUpdate: onUpdate)
            }
        }
    }

    public func unsubscribe() {
        subscriberCount = max(0, subscriberCount - 1)
        if subscriberCount == 0 {
            pumpTask?.cancel()
            pumpTask = nil
        }
    }

    private func isActive() -> Bool {
        subscriberCount > 0
    }

    /// `pollInterval`, doubled once per consecutive failed poll, capped at
    /// `maxPollInterval` — see `consecutiveFailures`.
    private func nextPollDelay() -> Duration {
        guard consecutiveFailures > 0 else { return pollInterval }
        let scaled = pollInterval * (1 << min(consecutiveFailures, 6))
        return min(scaled, Self.maxPollInterval)
    }

    private func pollOnce(onUpdate: @escaping @Sendable () async -> Void) async {
        let (data, _) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: self.clientName, reply: $1) }
        guard let data else {
            // Denied, or Sentry unreachable — either way, slow down.
            consecutiveFailures += 1
            return
        }
        consecutiveFailures = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(SystemSnapshot.self, from: data) else { return }
        guard snapshot.timestamp != lastTimestamp else { return }
        lastTimestamp = snapshot.timestamp
        await onUpdate()
    }
}
#endif
