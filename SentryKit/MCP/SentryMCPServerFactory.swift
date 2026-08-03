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
    public init() {}
    public func set(_ name: String) { self.name = name }
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
            let clientName = await clientIdentity.name
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
            let clientName = await clientIdentity.name
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
