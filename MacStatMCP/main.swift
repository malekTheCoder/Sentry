import Foundation
import MCP
import MacStatKit

// MacStatMCP — the stdio JSON-RPC binary from plan §13.2. An MCP client
// (Claude Desktop, Claude Code, Cursor, …) spawns this as a subprocess and
// talks to it over stdin/stdout; this binary in turn talks to the
// already-running `MacStat.app` over a local `NSXPCConnection` to the Mach
// service `MacStatXPCServiceName.machService`. It never touches IOKit,
// SQLite, or any of `StatsCoordinator`/`PowerControlService`/`HistoryStore`/
// `AlertEngine` directly — see `MacStatXPCServiceProtocol`'s doc comment for
// why that boundary matters (one sampling loop, one SQLite owner,
// permission gating lives in the app, not here).
//
// **Zero network, for real.** This file imports only `Foundation`, `MCP`
// (the local stdio/XPC-agnostic protocol library), and `MacStatKit`. No
// `URLSession`, no `Network.framework`, no socket of any kind — every tool
// call this binary answers comes from the XPC round-trip above. `AIAccessPane`
// makes the same claim in the Settings UI; this is the file that has to keep
// it true.

// MARK: - XPC client
//
// `MacStatXPCClient`/`ResumeOnce` now live in `MacStatKit/XPC/MacStatXPCClient.swift`
// so `MacStatCLI` (the standalone `macstat` binary) can share them instead
// of duplicating the connection/reply-race handling.

/// Captures the connecting MCP client's self-reported identity from the
/// `initialize` handshake, for the activity log (see
/// `MacStatXPCServiceProtocol`'s doc comment on why `clientName` is a label,
/// not an auth boundary). An `actor` because the initialize hook and every
/// tool-call handler run concurrently on the server's own task-per-request
/// model.
actor ClientIdentity {
    private(set) var name: String = "Unknown MCP Client"
    func set(_ name: String) { self.name = name }
}

// MARK: - Entry point

let xpcClient = MacStatXPCClient()
let clientIdentity = ClientIdentity()
let subscriptionPump = ResourceSubscriptionPump(xpcClient: xpcClient, clientName: "MacStat (resource subscription)")

let server = Server(
    name: "MacStat",
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

let transport = StdioTransport()

do {
    try await server.start(transport: transport) { clientInfo, _ in
        await clientIdentity.set(clientInfo.name)
    }
    // `server.start` returns once the connection is established; the
    // process needs to stay alive for the lifetime of the stdio session,
    // which ends when the parent (the MCP client) closes the pipe — at
    // which point `StdioTransport` finishes its read loop and this task
    // sleep is the only thing keeping the process from exiting first.
    try await Task.sleep(for: .seconds(365 * 24 * 60 * 60))
} catch {
    FileHandle.standardError.write("MacStatMCP failed to start: \(error)\n".data(using: .utf8) ?? Data())
    exit(1)
}
