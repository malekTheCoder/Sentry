import Foundation
import MCP
import MacStatKit

/// MCP Resource support (AI-agent-integration pass — see
/// MacStat-AI-Features-Research.md item #9). Before this, `MacStatMCP` only
/// advertised `tools` (`capabilities: .init(tools: .init(listChanged: false))`
/// in `main.swift`); every "live" read was the client re-polling
/// `get_system_snapshot` itself. This adds one Resource,
/// `macstat://system-snapshot`, with subscribe support: a long-lived client
/// (a Claude Code session, a Cursor background agent) calls
/// `resources/subscribe` once and then gets a `notifications/resources/updated`
/// push instead of having to poll a tool call repeatedly — cheaper in both
/// latency and token cost for the exact "watch the machine" pattern
/// `wait_until_ready`/`preflight_check` exist to replace with a single
/// blocking call, and a complement to them for clients that want a live feed
/// instead.
///
/// **Why polling under the hood, not a true push, is still honest here:**
/// `MacStatMCP` only talks to `MacStat.app` over synchronous XPC
/// request/reply calls (`MacStatXPCServiceProtocol`) — there's no
/// server-initiated push channel from the app to this process. So
/// `ResourceSubscriptionPump` polls `get_system_snapshot` on a short
/// interval while at least one MCP client is subscribed, and only emits a
/// `notifications/resources/updated` when the snapshot's timestamp actually
/// advances. The client-facing contract (subscribe once, get pushed
/// updates, no repeated `tools/call`) is real; what's saved is the client's
/// token cost, not MacStat's own poll loop, which already runs regardless
/// (`StatsCoordinator`'s tiered `AsyncStream`).
enum ResourceCatalog {
    static let systemSnapshotURI = "macstat://system-snapshot"

    static let resources: [Resource] = [
        Resource(
            name: "system-snapshot",
            uri: systemSnapshotURI,
            description: "Live current values for all enabled metrics — the same payload as the get_system_snapshot tool, but subscribable via resources/subscribe.",
            mimeType: "application/json"
        )
    ]

    static func read(uri: String, clientName: String, xpcClient: MacStatXPCClient) async throws -> ReadResource.Result {
        guard uri == systemSnapshotURI else {
            throw MCPError.invalidParams("Unknown resource URI '\(uri)'.")
        }
        let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
        guard let data, let text = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError(message ?? "MacStat denied this request.")
        }
        return ReadResource.Result(contents: [.text(text, uri: uri, mimeType: "application/json")])
    }
}

/// Polls `get_system_snapshot` on a fixed interval while `subscriberCount`
/// is above zero, and calls `onUpdate` whenever the snapshot's `timestamp`
/// field advances — see `ResourceCatalog`'s doc comment for why polling
/// happens here rather than this being a true push from `MacStat.app`.
actor ResourceSubscriptionPump {
    private let xpcClient: MacStatXPCClient
    private let clientName: String
    private let pollInterval: Duration
    private var subscriberCount = 0
    private var pumpTask: Task<Void, Never>?
    private var lastTimestamp: Date?

    init(xpcClient: MacStatXPCClient, clientName: String, pollInterval: Duration = .seconds(3)) {
        self.xpcClient = xpcClient
        self.clientName = clientName
        self.pollInterval = pollInterval
    }

    func subscribe(onUpdate: @escaping @Sendable () async -> Void) {
        subscriberCount += 1
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while await self.isActive() {
                try? await Task.sleep(for: await self.pollInterval)
                await self.pollOnce(onUpdate: onUpdate)
            }
        }
    }

    func unsubscribe() {
        subscriberCount = max(0, subscriberCount - 1)
        if subscriberCount == 0 {
            pumpTask?.cancel()
            pumpTask = nil
        }
    }

    private func isActive() -> Bool {
        subscriberCount > 0
    }

    private func pollOnce(onUpdate: @escaping @Sendable () async -> Void) async {
        let (data, _) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: self.clientName, reply: $1) }
        guard let data else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(SystemSnapshot.self, from: data) else { return }
        guard snapshot.timestamp != lastTimestamp else { return }
        lastTimestamp = snapshot.timestamp
        await onUpdate()
    }
}
