import Foundation

#if os(macOS)
import MCP

/// Captures the connecting MCP client's self-reported identity from the
/// `initialize` handshake, for the activity log (see
/// `SentryXPCServiceProtocol`'s doc comment on why `clientName` is a label,
/// not an auth boundary). An `actor` because the initialize hook and every
/// tool-call handler run concurrently on the server's own task-per-request
/// model.
public actor MCPClientIdentity {
    public private(set) var name: String = "Unknown MCP Client"

    /// Stable per-connection session ID (agent-session attribution pass):
    /// one `MCPClientIdentity` exists per server instance — one per spawned
    /// `SentryMCP` process for the stdio transport, one per
    /// `MCPRemoteServer` start for the remote transport — so a UUID minted
    /// at construction is exactly "stable for the lifetime of the
    /// connection/process," which is what `agent_activity_log.session_id`
    /// wants. Reused rather than re-derived anywhere else; every tool call
    /// carries it via `wireName`.
    public let sessionID = UUID().uuidString

    public init() {}
    public func set(_ name: String) { self.name = name }

    /// The composite `clientName` string every XPC call should send —
    /// carries `sessionID` alongside the display name without widening
    /// `SentryXPCServiceProtocol`'s 20 method signatures. See
    /// `AgentSessionIdentity` (SentryKit/Services/AgentSessionIdentity.swift)
    /// for the format and the trust model.
    public var wireName: String {
        AgentSessionIdentity.encode(clientName: name, sessionID: sessionID)
    }
}

/// Builds one fully-wired `Server` (tools, resources, subscriptions) — the
/// part of `SentryMCP/main.swift` that used to be transport-specific
/// bootstrapping is now shared, since both the stdio `SentryMCP` binary and
/// the in-app remote HTTP transport (`Sentry/App/MCPRemoteServer.swift`)
/// need the identical dispatch wiring and differ only in which `Transport`
/// they hand to `server.start(transport:)`.
public enum SentryMCPServerFactory {
    public static func makeServer(
        xpcClient: any MCPServiceCalling,
        clientIdentity: MCPClientIdentity,
        subscriptionPump: ResourceSubscriptionPump
    ) async -> Server {
        let server = Server(
            name: "Sentry",
            version: "0.1.0",
            capabilities: .init(
                resources: .init(subscribe: true, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPToolCatalog.tools)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: ResourceCatalog.resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            // `wireName`, not `name`: the composite string carries the
            // per-connection session ID to `MCPXPCService`'s durable
            // activity log — see `MCPClientIdentity.wireName`.
            let clientName = await clientIdentity.wireName
            return try await ResourceCatalog.read(uri: params.uri, clientName: clientName, xpcClient: xpcClient)
        }

        await server.withMethodHandler(ResourceSubscribe.self) { params in
            guard params.uri == ResourceCatalog.systemSnapshotURI else {
                throw MCPError.invalidParams("Unknown resource URI '\(params.uri)'.")
            }
            await subscriptionPump.subscribe {
                let notification = Message<ResourceUpdatedNotification>(
                    method: ResourceUpdatedNotification.name,
                    params: .init(uri: ResourceCatalog.systemSnapshotURI)
                )
                try? await server.notify(notification)
            }
            return Empty()
        }

        await server.withMethodHandler(ResourceUnsubscribe.self) { params in
            guard params.uri == ResourceCatalog.systemSnapshotURI else {
                throw MCPError.invalidParams("Unknown resource URI '\(params.uri)'.")
            }
            await subscriptionPump.unsubscribe()
            return Empty()
        }

        await server.withMethodHandler(CallTool.self) { params in
            // Same `wireName` reasoning as the ReadResource handler above.
            let clientName = await clientIdentity.wireName
            return await MCPToolCatalog.call(
                name: params.name,
                arguments: params.arguments ?? [:],
                clientName: clientName,
                xpcClient: xpcClient
            )
        }

        return server
    }
}
#endif
